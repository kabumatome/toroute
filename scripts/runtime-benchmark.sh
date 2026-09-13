#!/usr/bin/env bash
set -Eeuo pipefail
image=${1:?usage: runtime-benchmark.sh IMAGE OUTPUT_JSON}
output=${2:?usage: runtime-benchmark.sh IMAGE OUTPUT_JSON}
timeout=${BENCHMARK_TIMEOUT_SECONDS:-360}
name="toroute-benchmark-${RANDOM}-${RANDOM}"
cleanup(){ rc=$?; if (( rc != 0 )); then docker logs "$name" >&2 || true; fi; docker rm -f "$name" >/dev/null 2>&1 || true; exit "$rc"; }
trap cleanup EXIT
start_ns=$(date +%s%N)
docker run -d --name "$name" --read-only --cap-drop=ALL --security-opt=no-new-privileges --pids-limit 128   --tmpfs /run/toroute:uid=65532,gid=65532,mode=0700 --tmpfs /var/lib/toroute:uid=65532,gid=65532,mode=0700   -e TOROUTE_HTTP_ENABLED=true "$image" >/dev/null
deadline=$((SECONDS+timeout))
while (( SECONDS < deadline )); do
  state=$(docker inspect --format '{{.State.Status}}' "$name"); [[ $state == running ]] || { echo "container exited: $state" >&2; exit 1; }
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name")
  [[ $health == healthy ]] && break; [[ $health == unhealthy ]] && { echo 'container became unhealthy' >&2; exit 1; }; sleep 2
done
[[ $(docker inspect --format '{{.State.Health.Status}}' "$name") == healthy ]] || { echo 'Tor did not become healthy' >&2; exit 1; }
end_ns=$(date +%s%N); bootstrap_ms=$(( (end_ns-start_ns)/1000000 ))
TOROUTE_METRICS_PROFILE=full-http ./scripts/collect-running-metrics.sh "$image" "$name" "$bootstrap_ms" "$output"
echo 'runtime benchmark passed'
