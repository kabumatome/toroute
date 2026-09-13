#!/usr/bin/env bash
set -Eeuo pipefail

# Prevent Git for Windows/MSYS from rewriting URLs and container paths passed
# to native Windows executables. These variables are harmless on Linux.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
image=${1:?usage: live-smoke.sh IMAGE}
timeout=${LIVE_TIMEOUT_SECONDS:-360}
name="toroute-live-${RANDOM}-${RANDOM}"
platform_args=(); [[ -n ${DOCKER_PLATFORM:-} ]] && platform_args=(--platform "$DOCKER_PLATFORM")
start_ns=$(date +%s%N)
cleanup(){ rc=$?; if (( rc != 0 )); then docker logs "$name" >&2 || true; fi; docker rm -f "$name" >/dev/null 2>&1 || true; exit "$rc"; }
trap cleanup EXIT
docker run -d --name "$name" "${platform_args[@]}" --read-only --cap-drop=ALL --security-opt=no-new-privileges --pids-limit 128 \
  --tmpfs /run/toroute:uid=65532,gid=65532,mode=0700 --tmpfs /var/lib/toroute:uid=65532,gid=65532,mode=0700 \
  -e TOROUTE_HTTP_ENABLED=true -p 127.0.0.1::9050 -p 127.0.0.1::8118 "$image" >/dev/null
socks_port=$(docker port "$name" 9050/tcp | awk -F: 'NR==1{print $NF}')
http_port=$(docker port "$name" 8118/tcp | awk -F: 'NR==1{print $NF}')
[[ $socks_port =~ ^[0-9]+$ && $http_port =~ ^[0-9]+$ ]] || { echo 'failed to resolve ports' >&2; exit 1; }
deadline=$((SECONDS+timeout))
while (( SECONDS < deadline )); do
  state=$(docker inspect --format '{{.State.Status}}' "$name")
  [[ $state == running ]] || { echo "container exited: $state" >&2; exit 1; }
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name")
  [[ $health == healthy ]] && break
  [[ $health == unhealthy ]] && { echo 'container became unhealthy' >&2; exit 1; }
  sleep 3
done
[[ $(docker inspect --format '{{.State.Health.Status}}' "$name") == healthy ]] || { echo 'Tor did not become healthy' >&2; exit 1; }
healthy_ns=$(date +%s%N)
bootstrap_ms=$(( (healthy_ns-start_ns)/1000000 ))
for mode in socks http; do
  response=
  proxy_ok=false
  for attempt in 1 2 3; do
    curl_rc=0
    if [[ $mode == socks ]]; then
      response=$(curl --fail --silent --show-error --max-time 60 --socks5-hostname "127.0.0.1:$socks_port" https://check.torproject.org/api/ip) || curl_rc=$?
    else
      response=$(curl --fail --silent --show-error --max-time 60 --proxy "http://127.0.0.1:$http_port" https://check.torproject.org/api/ip) || curl_rc=$?
    fi
    if (( curl_rc == 0 )); then
      proxy_ok=true
      break
    fi
    echo "$mode Tor-check attempt $attempt failed (curl exit $curl_rc)" >&2
    sleep $((attempt*3))
  done
  [[ $proxy_ok == true ]] || { echo "$mode Tor-check failed after 3 attempts" >&2; exit 1; }
  if ! grep -Eq '"IsTor"[[:space:]]*:[[:space:]]*true' <<<"$response"; then
    echo "$mode Tor-check returned an invalid or non-Tor response" >&2
    exit 1
  fi
done
curl_rc=0
curl --fail --silent --show-error --max-time 60 --socks5-hostname "127.0.0.1:$socks_port" https://example.com/ >/dev/null || curl_rc=$?
if (( curl_rc != 0 )); then
  echo "SOCKS5 HTTPS probe failed (curl exit $curl_rc)" >&2
  exit "$curl_rc"
fi
curl_rc=0
curl --fail --silent --show-error --max-time 60 --proxy "http://127.0.0.1:$http_port" https://example.com/ >/dev/null || curl_rc=$?
if (( curl_rc != 0 )); then
  echo "HTTP CONNECT HTTPS probe failed (curl exit $curl_rc)" >&2
  exit "$curl_rc"
fi
if [[ -n ${LIVE_METRICS_OUTPUT:-} ]]; then
  TOROUTE_METRICS_PROFILE=full-http ./scripts/collect-running-metrics.sh "$image" "$name" "$bootstrap_ms" "$LIVE_METRICS_OUTPUT"
fi
echo 'live SOCKS5 and HTTP smoke tests passed'
