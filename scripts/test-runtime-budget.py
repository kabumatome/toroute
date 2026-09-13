#!/usr/bin/env python3
from __future__ import annotations
import json, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
SCRIPT=ROOT/'scripts/check-runtime-budget.py'
metrics={
    "schema_version":1,"profile":"full-http","image_size_bytes":10,
    "package_count":6,"bootstrap_milliseconds":20,
    "steady_memory_max_bytes":30,"idle_cpu_usec_per_second":40,"pids_max":5,
}
def run(budgets,*extra,metrics_value=metrics):
    with tempfile.TemporaryDirectory() as directory:
        base=Path(directory); mp=base/'metrics.json'; bp=base/'budgets.json'
        mp.write_text(json.dumps(metrics_value)); bp.write_text(json.dumps(budgets))
        return subprocess.run([str(SCRIPT),str(mp),'--budgets',str(bp),*extra],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
fields=("max_image_size_bytes","max_package_count","max_bootstrap_milliseconds","max_steady_memory_bytes","max_idle_cpu_usec_per_second","max_pids")
unbaselined={"schema_version":1,"status":"unbaselined",**{name:None for name in fields}}
assert run(unbaselined).returncode==0
assert run(unbaselined,'--require-baseline').returncode!=0
active={
    "schema_version":1,"status":"active","max_image_size_bytes":10,
    "max_package_count":6,"max_bootstrap_milliseconds":20,
    "max_steady_memory_bytes":30,"max_idle_cpu_usec_per_second":40,"max_pids":5,
}
assert run(active,'--require-baseline').returncode==0
for name, value in list(active.items()):
    if name.startswith('max_'):
        failed=dict(active); failed[name]=value-1
        assert run(failed).returncode!=0, name
assert subprocess.run([str(SCRIPT),'--budgets',str(ROOT/'security/runtime-budgets.json'),'--validate-budget-only','--require-baseline'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10).returncode==0
assert subprocess.run([str(SCRIPT),str(ROOT/'security/runtime-baseline-full-http-amd64.json'),'--budgets',str(ROOT/'security/runtime-budgets.json'),'--require-baseline'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10).returncode==0
print('runtime budget policy tests passed')
