#!/usr/bin/env python3
"""Create a public-safe summary from private ToRoute validation evidence."""
from __future__ import annotations

import argparse
from datetime import datetime
import json
import math
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

MAX_INPUT_BYTES = 2 << 20
EXPECTED_CHECKS = (
    "Windows PowerShell runtime self-test",
    "Docker Desktop / Compose / Buildx前提確認",
    "amd64 runtime / netprobe / proxycheckビルド",
    "イメージmetadata・non-root・設定境界",
    "hardened Compose起動・readiness",
    "client network直通防止・proxy到達",
    "SOCKS5 remote DNS・Tor実通信",
    "HTTP CONNECT・Tor実通信",
    "NEWNYM・Control往復",
    "runtime metrics・package inventory",
    "ログ秘密情報・異常文字列監査",
    "arm64 QEMU build・config validation",
)
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+-rc\.\d+$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
UTC_TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$")


class EvidenceReader:
    def __init__(self, source: Path) -> None:
        self.source = source
        self.archive: zipfile.ZipFile | None = None
        if source.is_file():
            self.archive = zipfile.ZipFile(source)
            names: set[str] = set()
            for info in self.archive.infolist():
                path = PurePosixPath(info.filename.replace("\\", "/"))
                if path.is_absolute() or ".." in path.parts:
                    raise ValueError(f"unsafe ZIP entry: {info.filename}")
                normalized = path.as_posix()
                if normalized in names:
                    raise ValueError(f"duplicate ZIP entry: {normalized}")
                names.add(normalized)

    def close(self) -> None:
        if self.archive is not None:
            self.archive.close()

    def read(self, name: str) -> str:
        if self.archive is not None:
            try:
                info = self.archive.getinfo(name)
            except KeyError as exc:
                raise ValueError(f"missing evidence file: {name}") from exc
            if info.file_size > MAX_INPUT_BYTES:
                raise ValueError(f"evidence file is too large: {name}")
            data = self.archive.read(info)
        else:
            path = self.source / name
            if not path.is_file():
                raise ValueError(f"missing evidence file: {name}")
            if path.stat().st_size > MAX_INPUT_BYTES:
                raise ValueError(f"evidence file is too large: {name}")
            data = path.read_bytes()
        return data.decode("utf-8-sig")


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json_value(reader: EvidenceReader, name: str) -> Any:
    return json.loads(reader.read(name), object_pairs_hook=unique_object)


def parse_json(reader: EvidenceReader, name: str) -> dict[str, Any]:
    value = parse_json_value(reader, name)
    if not isinstance(value, dict):
        raise ValueError(f"{name} must contain a JSON object")
    return value


def integer(value: Any, name: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{name} must be an integer >= {minimum}")
    return value


def number(value: Any, name: str, minimum: float = 0) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value < minimum
    ):
        raise ValueError(f"{name} must be a number >= {minimum}")
    return float(value)


def build_summary(reader: EvidenceReader, budgets: dict[str, Any]) -> dict[str, Any]:
    result = parse_json(reader, "result.json")
    metrics = parse_json(reader, "runtime-metrics.json")
    image_inspect = parse_json_value(reader, "image-inspect.json")

    if result.get("schema_version") != 1 or metrics.get("schema_version") != 1:
        raise ValueError("unsupported evidence schema")
    if metrics.get("profile") != "full-http":
        raise ValueError("runtime metrics must use the full-http profile")
    version = result.get("toroute_version")
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        raise ValueError("invalid ToRoute version")
    generated = result.get("generated_at_utc")
    if not isinstance(generated, str) or not UTC_TIMESTAMP_RE.fullmatch(generated):
        raise ValueError("invalid generation timestamp")
    try:
        datetime.fromisoformat(generated.removesuffix("Z") + "+00:00")
    except ValueError as exc:
        raise ValueError("invalid generation timestamp") from exc

    raw_checks = result.get("checks")
    if not isinstance(raw_checks, list) or len(raw_checks) != len(EXPECTED_CHECKS):
        raise ValueError("unexpected validation check count")
    checks = []
    for expected, raw in zip(EXPECTED_CHECKS, raw_checks, strict=True):
        if not isinstance(raw, dict) or raw.get("name") != expected:
            raise ValueError(f"unexpected validation check; wanted {expected}")
        status = raw.get("status")
        if status not in {"passed", "failed", "skipped"}:
            raise ValueError(f"invalid validation status for {expected}")
        checks.append({
            "name": expected,
            "status": status,
            "elapsed_seconds": round(number(raw.get("elapsed_seconds"), "elapsed_seconds"), 3),
        })

    identity = reader.read("source-identity.txt").strip().lower()
    if not isinstance(image_inspect, list) or len(image_inspect) != 1:
        raise ValueError("image-inspect.json must contain exactly one image")
    image = image_inspect[0]
    if not isinstance(image, dict):
        raise ValueError("image-inspect.json image must be an object")
    config = image.get("Config")
    labels = config.get("Labels") if isinstance(config, dict) else None
    if not isinstance(labels, dict):
        raise ValueError("image-inspect.json must contain OCI labels")
    image_revision = labels.get("org.opencontainers.image.revision")
    image_version = labels.get("org.opencontainers.image.version")
    identity_consistent = image_revision == identity and image_version == version
    verified_identity = bool(COMMIT_RE.fullmatch(identity)) and identity_consistent
    identity_status = (
        "verified-git-commit"
        if verified_identity
        else "inconsistent-evidence"
        if not identity_consistent
        else "unverified-non-commit"
    )
    metric_values = {
        "image_size_bytes": integer(metrics.get("image_size_bytes"), "image_size_bytes"),
        "package_count": integer(metrics.get("package_count"), "package_count"),
        "bootstrap_milliseconds": integer(metrics.get("bootstrap_milliseconds"), "bootstrap_milliseconds"),
        "steady_memory_max_bytes": integer(metrics.get("steady_memory_max_bytes"), "steady_memory_max_bytes"),
        "idle_cpu_usec_per_second": integer(metrics.get("idle_cpu_usec_per_second"), "idle_cpu_usec_per_second"),
        "pids_max": integer(metrics.get("pids_max"), "pids_max"),
    }
    budget_keys = {
        "image_size_bytes": "max_image_size_bytes",
        "package_count": "max_package_count",
        "bootstrap_milliseconds": "max_bootstrap_milliseconds",
        "steady_memory_max_bytes": "max_steady_memory_bytes",
        "idle_cpu_usec_per_second": "max_idle_cpu_usec_per_second",
        "pids_max": "max_pids",
    }
    comparisons = {}
    for metric, budget_key in budget_keys.items():
        limit = integer(budgets.get(budget_key), budget_key)
        comparisons[metric] = {
            "observed": metric_values[metric],
            "limit": limit,
            "passed": metric_values[metric] <= limit,
        }
    validation_succeeded = result.get("succeeded") is True and all(
        item["status"] == "passed" for item in checks
    )
    budgets_passed = all(item["passed"] for item in comparisons.values())
    return {
        "schema_version": 1,
        "project": "ToRoute",
        "evidence_profile": "windows-docker-full",
        "toroute_version": version,
        "generated_at_utc": generated,
        "validation": {
            "succeeded": validation_succeeded,
            "quick_mode": result.get("quick_mode") is True,
            "arm64_requested": result.get("arm64_requested") is True,
            "checks": checks,
        },
        "source": {
            "identity_verified": verified_identity,
            "evidence_consistent": identity_consistent,
            "revision": identity if verified_identity else None,
            "status": identity_status,
        },
        "runtime_budget": {
            "profile": "full-http",
            "passed": budgets_passed,
            "metrics": comparisons,
        },
        "release_gate_eligible": validation_succeeded and budgets_passed and verified_identity,
        "publication": {
            "this_summary_contains_raw_operational_data": False,
            "raw_evidence_publishable": False,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--budgets", type=Path, default=Path("security/runtime-budgets.json"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    budgets = json.loads(args.budgets.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(budgets, dict) or budgets.get("status") != "active":
        raise SystemExit("runtime budget must be an active JSON object")
    reader = EvidenceReader(args.evidence)
    try:
        summary = build_summary(reader, budgets)
    finally:
        reader.close()
    rendered = json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)


if __name__ == "__main__":
    main()
