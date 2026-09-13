#!/usr/bin/env bash
set -Eeuo pipefail
image=${1:?usage: collect-running-metrics.sh IMAGE CONTAINER BOOTSTRAP_MS OUTPUT_JSON}
container=${2:?usage: collect-running-metrics.sh IMAGE CONTAINER BOOTSTRAP_MS OUTPUT_JSON}
bootstrap_ms=${3:?usage: collect-running-metrics.sh IMAGE CONTAINER BOOTSTRAP_MS OUTPUT_JSON}
output=${4:?usage: collect-running-metrics.sh IMAGE CONTAINER BOOTSTRAP_MS OUTPUT_JSON}
sample_seconds=${RUNTIME_SAMPLE_SECONDS:-10}
profile=${TOROUTE_METRICS_PROFILE:-full-http}
[[ $bootstrap_ms =~ ^[0-9]+$ ]] || { echo 'bootstrap milliseconds must be an integer' >&2; exit 1; }
[[ $sample_seconds =~ ^[1-9][0-9]*$ && $sample_seconds -le 60 ]] || { echo 'RUNTIME_SAMPLE_SECONDS must be 1..60' >&2; exit 1; }
[[ $profile =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || { echo 'TOROUTE_METRICS_PROFILE has invalid syntax' >&2; exit 1; }
mkdir -p "$(dirname "$output")"; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
./scripts/image-inventory.sh "$image" "$tmp/inventory.json" >/dev/null
read_cgroup() {
  docker exec "$container" /bin/sh -c '
    if [ -r /sys/fs/cgroup/memory.current ]; then memory=$(cat /sys/fs/cgroup/memory.current); else memory=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes); fi
    if [ -r /sys/fs/cgroup/pids.current ]; then pids=$(cat /sys/fs/cgroup/pids.current); else pids=$(cat /sys/fs/cgroup/pids/pids.current); fi
    if [ -r /sys/fs/cgroup/cpu.stat ]; then cpu=$(sed -n "s/^usage_usec //p" /sys/fs/cgroup/cpu.stat); else cpu=$(( $(cat /sys/fs/cgroup/cpuacct/cpuacct.usage) / 1000 )); fi
    printf "%s %s %s\n" "$memory" "$pids" "$cpu"
  '
}
samples=6
interval=$(python3 - "$sample_seconds" "$samples" <<'PY2'
import sys
print(float(sys.argv[1]) / (int(sys.argv[2]) - 1))
PY2
)
: >"$tmp/samples.tsv"
for ((i=0; i<samples; i++)); do
  read -r memory pids cpu < <(read_cgroup)
  [[ $memory =~ ^[0-9]+$ && $pids =~ ^[0-9]+$ && $cpu =~ ^[0-9]+$ ]] || { echo 'invalid cgroup metric' >&2; exit 1; }
  printf '%s\t%s\t%s\n' "$memory" "$pids" "$cpu" >>"$tmp/samples.tsv"
  (( i + 1 == samples )) || sleep "$interval"
done
python3 - "$tmp/inventory.json" "$tmp/samples.tsv" "$bootstrap_ms" "$sample_seconds" "$profile" "$output" <<'PY2'
import json, pathlib, statistics, sys
inventory_path, samples_path, bootstrap_text, duration_text, profile, output = sys.argv[1:]
inventory=json.loads(pathlib.Path(inventory_path).read_text(encoding="utf-8")); samples=[]
for line in pathlib.Path(samples_path).read_text(encoding="utf-8").splitlines():
    memory,pids,cpu=map(int,line.split("\t")); samples.append({"memory_bytes":memory,"pids":pids,"cpu_usage_usec":cpu})
if len(samples)<2: raise SystemExit("at least two cgroup samples are required")
duration=int(duration_text); cpu_delta=samples[-1]["cpu_usage_usec"]-samples[0]["cpu_usage_usec"]
if cpu_delta<0: raise SystemExit("cgroup CPU usage moved backwards")
result={"schema_version":1,"profile":profile,"image_reference":inventory["image_reference"],"image_id":inventory["image_id"],
"image_size_bytes":inventory["image_size_bytes"],"distribution_id":inventory.get("distribution",{}).get("ID",""),
"distribution_version":inventory.get("distribution",{}).get("VERSION_ID",""),"package_count":inventory["package_count"],
"package_installed_size_kib":inventory["package_installed_size_kib"],"bootstrap_milliseconds":int(bootstrap_text),
"sample_duration_seconds":duration,"steady_memory_min_bytes":min(x["memory_bytes"] for x in samples),
"steady_memory_median_bytes":int(statistics.median(x["memory_bytes"] for x in samples)),
"steady_memory_max_bytes":max(x["memory_bytes"] for x in samples),"pids_max":max(x["pids"] for x in samples),
"idle_cpu_usage_delta_usec":cpu_delta,"idle_cpu_usec_per_second":int(round(cpu_delta/duration)),"samples":samples}
pathlib.Path(output).write_text(json.dumps(result, indent=2, sort_keys=True)+"\n", encoding="utf-8")
print(f"runtime metrics written to {output}")
PY2
./scripts/check-runtime-budget.py "$output"
