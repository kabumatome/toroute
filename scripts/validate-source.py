#!/usr/bin/env python3
"""Run ToRoute source gates with bounded, isolated process groups."""
from __future__ import annotations

import os
import signal
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VALIDATION_TMP = ROOT / ".tmp-validation"


@dataclass(frozen=True)
class Gate:
    name: str
    command: tuple[str, ...]
    timeout: int
    env: dict[str, str] | None = None


def environment(extra: dict[str, str] | None = None) -> dict[str, str]:
    result = os.environ.copy()
    result["PYTHONDONTWRITEBYTECODE"] = "1"
    if extra:
        result.update(extra)
    return result


def validation_tmpdir() -> Path:
    VALIDATION_TMP.mkdir(parents=True, exist_ok=True)
    return VALIDATION_TMP


def terminate_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass


def ensure_command_available(gate: Gate) -> None:
    executable = gate.command[0]
    if "/" not in executable and shutil.which(executable) is None:
        raise SystemExit(f"required command not found for {gate.name}: {executable}")


def run_parallel(gates: tuple[Gate, ...]) -> None:
    with tempfile.TemporaryDirectory(prefix="toroute-validation-", dir=validation_tmpdir()) as directory:
        root = Path(directory)
        running: list[tuple[Gate, subprocess.Popen[bytes], Path, float]] = []
        for index, gate in enumerate(gates):
            ensure_command_available(gate)
            log = root / f"{index:02d}.log"
            handle = log.open("wb")
            print(f"==> {gate.name}", flush=True)
            process = subprocess.Popen(
                gate.command,
                cwd=ROOT,
                env=environment(gate.env),
                stdout=handle,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            handle.close()
            running.append((gate, process, log, time.monotonic()))

        failures: list[str] = []
        while running:
            now = time.monotonic()
            remaining = []
            for gate, process, log, started in running:
                code = process.poll()
                if code is None and now - started > gate.timeout:
                    terminate_group(process)
                    failures.append(f"{gate.name}: timed out after {gate.timeout}s")
                    code = process.poll()
                if code is None:
                    remaining.append((gate, process, log, started))
                    continue
                output = log.read_text(encoding="utf-8", errors="replace")
                if output:
                    print(output, end="" if output.endswith("\n") else "\n")
                duration = time.monotonic() - started
                if code != 0:
                    failures.append(f"{gate.name}: exited {code}")
                else:
                    print(f"<== {gate.name}: passed in {duration:.2f}s", flush=True)
            running = remaining
            if running:
                time.sleep(0.05)
        if failures:
            raise SystemExit("source validation failed:\n- " + "\n- ".join(failures))


def run_serial(gate: Gate) -> None:
    ensure_command_available(gate)
    print(f"==> {gate.name}", flush=True)
    started = time.monotonic()
    process = subprocess.Popen(
        gate.command,
        cwd=ROOT,
        env=environment(gate.env),
        start_new_session=True,
    )
    try:
        code = process.wait(timeout=gate.timeout)
    except subprocess.TimeoutExpired:
        terminate_group(process)
        raise SystemExit(f"gate timed out after {gate.timeout}s: {gate.name}")
    if code != 0:
        raise SystemExit(f"gate failed ({code}): {gate.name}")
    print(f"<== {gate.name}: passed in {time.monotonic() - started:.2f}s", flush=True)


def main() -> None:
    started = time.monotonic()
    run_parallel((
        Gate(
            "format",
            (
                "bash",
                "-c",
                "command -v gofmt >/dev/null || { echo 'gofmt: command not found' >&2; exit 127; }; files=$(gofmt -l cmd internal tests); test -z \"$files\" || { printf '%s\\n' \"$files\"; exit 1; }",
            ),
            30,
        ),
        Gate("privacy scan", ("./scripts/privacy-scan.sh",), 60),
        Gate("OCI / attestation / vulnerability policy", ("python3", "./scripts/test-policy-tools.py"), 60),
        Gate("runtime budget policy", ("python3", "./scripts/test-runtime-budget.py"), 45),
        Gate("release tooling", ("./scripts/test-release-tools.sh",), 120, {"TMPDIR": str(validation_tmpdir())}),
        Gate("repository and workflow policy", ("./scripts/validate-repository.sh",), 90),
        Gate("ShellCheck", ("bash", "-c", "shellcheck scripts/*.sh"), 60),
        Gate("Bridge harness preflight", ("./scripts/test-bridge-live-harness.sh",), 30),
    ))
    # Compiler and race-linker work is intentionally serialized after the
    # packaging/policy gates. Concurrency here only increases peak memory and
    # can stall constrained CI or developer machines without adding coverage.
    run_serial(Gate("go vet", ("go", "vet", "./..."), 120, {"GOMAXPROCS": "2"}))
    run_serial(Gate("race tests and coverage", ("./scripts/test-go.sh",), 240, {"GO_TEST_GOMAXPROCS": "2", "GO_TEST_JOBS": "1"}))
    print(f"source validation passed in {time.monotonic() - started:.2f}s")


if __name__ == "__main__":
    main()
