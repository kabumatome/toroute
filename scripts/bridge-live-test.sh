#!/usr/bin/env bash
set -Eeuo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

image=${1:?usage: bridge-live-test.sh IMAGE BRIDGE_FILE}
source_arg=${2:?usage: bridge-live-test.sh IMAGE BRIDGE_FILE}

[[ -f $source_arg && ! -L $source_arg ]] || { echo 'Bridge input must be a regular non-symlink file' >&2; exit 1; }
source_dir=$(cd "$(dirname "$source_arg")" && pwd -P)
source_path="$source_dir/$(basename "$source_arg")"
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n $repo_root ]]; then
  repo_root=$(cd "$repo_root" && pwd -P)
  case $source_path in
    "$repo_root"|"$repo_root"/*)
      echo 'Bridge input must be stored outside the Git repository' >&2
      exit 1
      ;;
  esac
fi
[[ -s $source_path ]] || { echo 'Bridge input is empty' >&2; exit 1; }
source_bytes=$(wc -c < "$source_path")
(( source_bytes <= 1048576 )) || { echo 'Bridge input exceeds 1048576 bytes' >&2; exit 1; }

name="toroute-bridge-${RANDOM}-${RANDOM}"
volume="${name}-secret"
started=false
cleanup() {
  cleanup_rc=$?
  if [[ $started == true ]]; then
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
  exit "$cleanup_rc"
}
trap cleanup EXIT

docker volume create "$volume" >/dev/null
# The secret travels only over stdin. It is never placed in argv or environment.
docker run --rm -i --network none --read-only --user 0:0 \
  --cap-drop=ALL --cap-add=CHOWN --security-opt=no-new-privileges --pids-limit 32 \
  --mount "type=volume,source=$volume,target=/secure" \
  --entrypoint /bin/sh "$image" -ec \
  'umask 077; cat > /secure/bridges; chmod 0600 /secure/bridges; chown 65532:65532 /secure/bridges' \
  < "$source_path"

docker run -d --name "$name" --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --pids-limit 128 \
  --tmpfs "/run/toroute:uid=65532,gid=65532,mode=0700" \
  --tmpfs "/var/lib/toroute:uid=65532,gid=65532,mode=0700" \
  --mount "type=volume,source=$volume,target=/run/bridge-input,readonly" \
  -e TOROUTE_BRIDGES_FILE=/run/bridge-input/bridges \
  -p 127.0.0.1::9050 "$image" >/dev/null
started=true

deadline=$((SECONDS+420))
while (( SECONDS < deadline )); do
  state=$(docker inspect --format '{{.State.Status}}' "$name")
  [[ $state == running ]] || break
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name")
  [[ $health == healthy ]] && break
  [[ $health == unhealthy ]] && break
  sleep 3
done

logs=$(docker logs "$name" 2>&1 || true)
while IFS= read -r secret_line; do
  secret_line=${secret_line%$'\r'}
  [[ -z $secret_line || $secret_line == \#* ]] && continue
  if grep -Fq -- "$secret_line" <<<"$logs"; then
    echo 'SECURITY FAILURE: a Bridge line appeared in container logs' >&2
    exit 1
  fi
done < "$source_path"

if [[ $(docker inspect --format '{{.State.Running}}' "$name") != true ]]; then
  echo 'Bridge container exited before becoming healthy; logs suppressed to protect Bridge data' >&2
  exit 1
fi
if [[ $(docker inspect --format '{{.State.Health.Status}}' "$name") != healthy ]]; then
  echo 'Bridge Tor bootstrap did not become healthy within 420 seconds; logs suppressed to protect Bridge data' >&2
  exit 1
fi

socks_port=$(docker port "$name" 9050/tcp | awk -F: 'NR==1{print $NF}')
[[ $socks_port =~ ^[0-9]+$ ]] || { echo 'failed to resolve the local SOCKS port' >&2; exit 1; }
response=
curl_rc=0
response=$(curl --fail --silent --show-error --max-time 90 \
  --socks5-hostname "127.0.0.1:$socks_port" https://check.torproject.org/api/ip) || curl_rc=$?
if (( curl_rc != 0 )); then
  echo "Bridge SOCKS5 Tor-check failed (curl exit $curl_rc)" >&2
  exit 1
fi
if ! grep -Eq '"IsTor"[[:space:]]*:[[:space:]]*true' <<<"$response"; then
  echo 'Bridge SOCKS5 check returned an invalid or non-Tor response' >&2
  exit 1
fi

echo 'Bridge obfs4 bootstrap and SOCKS5 Tor path passed'
