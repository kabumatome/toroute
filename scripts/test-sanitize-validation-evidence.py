#!/usr/bin/env python3
"""Regression test for public-safe validation evidence summaries."""
from __future__ import annotations

import json
import subprocess
import tempfile
import warnings
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CHECKS = (
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


def main() -> None:
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        archive = base / "evidence.zip"
        budgets = base / "budgets.json"
        result = {
            "schema_version": 1,
            "toroute_version": "0.4.0-rc.12",
            "generated_at_utc": "2026-09-13T00:00:00Z",
            "succeeded": True,
            "quick_mode": False,
            "arm64_requested": True,
            "checks": [
                {"name": name, "status": "passed", "elapsed_seconds": 1.25, "detail": ""}
                for name in CHECKS
            ],
        }
        metrics = {
            "schema_version": 1,
            "profile": "full-http",
            "image_size_bytes": 100,
            "package_count": 10,
            "bootstrap_milliseconds": 1000,
            "steady_memory_max_bytes": 1000,
            "idle_cpu_usec_per_second": 100,
            "pids_max": 5,
        }
        limits = {
            "status": "active",
            "max_image_size_bytes": 200,
            "max_package_count": 20,
            "max_bootstrap_milliseconds": 2000,
            "max_steady_memory_bytes": 2000,
            "max_idle_cpu_usec_per_second": 200,
            "max_pids": 10,
        }
        image_inspect = [{
            "Config": {"Labels": {
                "org.opencontainers.image.revision": "source-archive",
                "org.opencontainers.image.version": "0.4.0-rc.12",
            }}
        }]
        budgets.write_text(json.dumps(limits), encoding="utf-8")
        with zipfile.ZipFile(archive, "w") as handle:
            handle.writestr("result.json", json.dumps(result))
            handle.writestr("runtime-metrics.json", json.dumps(metrics))
            handle.writestr("image-inspect.json", json.dumps(image_inspect))
            handle.writestr("source-identity.txt", "source-archive\n")
            handle.writestr("commands.log", "C:\\Users\\PrivateName 198.51.100.10 secret=do-not-copy")
        completed = subprocess.run(
            [str(ROOT / "sanitize-validation-evidence.py"), str(archive), "--budgets", str(budgets)],
            check=True,
            capture_output=True,
            text=True,
        )
        output = completed.stdout
        for forbidden in ("PrivateName", "198.51.100.10", "do-not-copy", "commands.log"):
            if forbidden in output:
                raise SystemExit(f"sanitized output leaked {forbidden}")
        summary = json.loads(output)
        assert summary["validation"]["succeeded"] is True
        assert summary["runtime_budget"]["passed"] is True
        assert summary["source"]["identity_verified"] is False
        assert summary["source"]["evidence_consistent"] is True
        assert summary["release_gate_eligible"] is False
        assert summary["publication"]["raw_evidence_publishable"] is False

        result["generated_at_utc"] = "secret-that-is-not-a-timestamp"
        invalid_timestamp = base / "invalid-timestamp.zip"
        with zipfile.ZipFile(invalid_timestamp, "w") as handle:
            handle.writestr("result.json", json.dumps(result))
            handle.writestr("runtime-metrics.json", json.dumps(metrics))
            handle.writestr("image-inspect.json", json.dumps(image_inspect))
            handle.writestr("source-identity.txt", "source-archive\n")
        rejected = subprocess.run(
            [str(ROOT / "sanitize-validation-evidence.py"), str(invalid_timestamp), "--budgets", str(budgets)],
            capture_output=True,
            text=True,
        )
        assert rejected.returncode != 0
        assert "secret-that-is-not-a-timestamp" not in rejected.stdout

        result["generated_at_utc"] = "2026-09-13T00:00:00Z"
        mismatch = base / "identity-mismatch.zip"
        with zipfile.ZipFile(mismatch, "w") as handle:
            handle.writestr("result.json", json.dumps(result))
            handle.writestr("runtime-metrics.json", json.dumps(metrics))
            handle.writestr("image-inspect.json", json.dumps(image_inspect))
            handle.writestr("source-identity.txt", "a" * 40 + "\n")
        completed = subprocess.run(
            [str(ROOT / "sanitize-validation-evidence.py"), str(mismatch), "--budgets", str(budgets)],
            check=True,
            capture_output=True,
            text=True,
        )
        mismatch_summary = json.loads(completed.stdout)
        assert mismatch_summary["source"]["identity_verified"] is False
        assert mismatch_summary["source"]["evidence_consistent"] is False
        assert mismatch_summary["source"]["revision"] is None

        duplicate = base / "duplicate.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(duplicate, "w") as handle:
                handle.writestr("result.json", "{}")
                handle.writestr("result.json", "{}")
        rejected = subprocess.run(
            [str(ROOT / "sanitize-validation-evidence.py"), str(duplicate), "--budgets", str(budgets)],
            capture_output=True,
            text=True,
        )
        assert rejected.returncode != 0
        assert "duplicate ZIP entry" in rejected.stderr
    print("validation evidence sanitizer tests passed")


if __name__ == "__main__":
    main()
