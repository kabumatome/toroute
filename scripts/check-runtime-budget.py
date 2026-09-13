#!/usr/bin/env python3
"""Validate ToRoute runtime metrics against reviewed release budgets."""
from __future__ import annotations
import argparse, json
from pathlib import Path
FIELDS = {
    "max_image_size_bytes": "image_size_bytes",
    "max_package_count": "package_count",
    "max_bootstrap_milliseconds": "bootstrap_milliseconds",
    "max_steady_memory_bytes": "steady_memory_max_bytes",
    "max_idle_cpu_usec_per_second": "idle_cpu_usec_per_second",
    "max_pids": "pids_max",
}
def load_object(path: str, label: str) -> dict:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"unable to read {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must be a JSON object")
    return value

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("metrics", nargs="?")
    parser.add_argument("--budgets", default="security/runtime-budgets.json")
    parser.add_argument("--require-baseline", action="store_true")
    parser.add_argument("--validate-budget-only", action="store_true")
    args = parser.parse_args()
    budgets = load_object(args.budgets, "runtime budgets")
    if budgets.get("schema_version") != 1:
        raise SystemExit("unsupported runtime budget schema")
    status = budgets.get("status")
    if status not in {"unbaselined", "active"}:
        raise SystemExit("runtime budget status must be unbaselined or active")
    configured = 0
    for budget_name in FIELDS:
        limit = budgets.get(budget_name)
        if limit is None:
            continue
        if not isinstance(limit, int) or limit <= 0:
            raise SystemExit(f"{budget_name} must be null or a positive integer")
        configured += 1
    if status == "active" and configured != len(FIELDS):
        raise SystemExit("active runtime budgets must configure every limit")
    if args.require_baseline and status != "active":
        raise SystemExit("stable release requires active runtime budgets")
    if args.validate_budget_only:
        print("runtime budget configuration is valid")
        return 0
    if not args.metrics:
        raise SystemExit("metrics path is required unless --validate-budget-only is used")
    metrics = load_object(args.metrics, "runtime metrics")
    if metrics.get("schema_version") != 1:
        raise SystemExit("unsupported runtime metrics schema")
    if metrics.get("profile") != "full-http":
        raise SystemExit("runtime budgets currently apply only to the full-http profile")
    missing = [name for name in FIELDS.values() if not isinstance(metrics.get(name), int) or metrics[name] < 0]
    if missing:
        raise SystemExit("runtime metrics are missing non-negative integers: " + ", ".join(missing))
    failures = []
    for budget_name, metric_name in FIELDS.items():
        limit = budgets.get(budget_name)
        if limit is not None and metrics[metric_name] > limit:
            failures.append(f"{metric_name}={metrics[metric_name]} exceeds {budget_name}={limit}")
    if failures:
        raise SystemExit("runtime budget failed: " + "; ".join(failures))
    print("runtime metrics recorded; budgets are not baselined yet" if status == "unbaselined" else "runtime budget passed")
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
