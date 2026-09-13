#!/usr/bin/env bash
set -Eeuo pipefail
image=${1:?usage: docker-config-test.sh IMAGE}
platform_args=(); [[ -n ${DOCKER_PLATFORM:-} ]] && platform_args=(--platform "$DOCKER_PLATFORM")
run=(docker run --rm "${platform_args[@]}" --read-only --cap-drop=ALL --security-opt=no-new-privileges --pids-limit 128 --tmpfs "/run/toroute:uid=65532,gid=65532,mode=0700" --tmpfs "/var/lib/toroute:uid=65532,gid=65532,mode=0700")
"${run[@]}" "$image" check-config
json=$("${run[@]}" "$image" print-config --format json)
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["socks_address"]=="0.0.0.0:9050" and d["http_enabled"] is False' <<<"$json"
torrc=$("${run[@]}" "$image" print-config --format torrc)
grep -qx 'ClientOnly 1' <<<"$torrc"
grep -qx 'ControlPort 0' <<<"$torrc"
grep -qx 'SafeSocks 1' <<<"$torrc"
grep -q '^SocksPort .*IsolateClientAddr IsolateSOCKSAuth' <<<"$torrc"
http=$("${run[@]}" -e TOROUTE_HTTP_ENABLED=true "$image" print-config --format privoxy)
grep -q '^forward-socks5t / 127.0.0.1:9050 \.$' <<<"$http"
expect_failure(){ local desc=$1; shift; if "$@" >/dev/null 2>&1; then echo "unexpected success: $desc" >&2; exit 1; fi; }
expect_failure unknown-variable "${run[@]}" -e TOROUTE_UNKNOWN=1 "$image" check-config
expect_failure binary-override "${run[@]}" -e TOROUTE_TOR_BINARY=/tmp/tor "$image" check-config
expect_failure generic-tor-injection "${run[@]}" -e TOR_SocksPort= "$image" check-config
expect_failure empty-http "${run[@]}" -e TOROUTE_HTTP_ENABLED= "$image" check-config
expect_failure role-change "${run[@]}" -e EXITNODE=1 "$image" check-config
expect_failure shared-data-dir "${run[@]}" -e TOROUTE_DATA_DIR=/tmp "$image" check-config
uid=$("${run[@]}" --entrypoint /usr/bin/id "$image" -u)
[[ $uid == 65532 ]] || { echo "unexpected uid $uid" >&2; exit 1; }
echo 'container configuration tests passed'
