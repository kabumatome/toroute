#!/usr/bin/env python3
"""Validate ToRoute's exact OCI runtime and attestation manifest shape."""
from __future__ import annotations

import argparse
import json
import re
import sys
from typing import BinaryIO

EXPECTED = {("linux", "amd64"), ("linux", "arm64")}
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
MAX_INPUT = 16 << 20


def fail(message: str) -> "None":
    raise SystemExit("manifest identity error: " + message)


def validate_stream(stream: BinaryIO) -> dict[str, str]:
    raw = stream.read(MAX_INPUT + 1)
    if len(raw) > MAX_INPUT:
        fail(f"input exceeds {MAX_INPUT} bytes")
    try:
        data = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"invalid JSON: {exc}")
    if not isinstance(data, dict) or not isinstance(data.get("manifests"), list):
        fail("manifests array missing")

    runtime: dict[tuple[str, str], str] = {}
    attestations: dict[str, list[str]] = {}
    for position, manifest in enumerate(data["manifests"], 1):
        if not isinstance(manifest, dict):
            fail(f"descriptor {position} is not an object")
        digest = manifest.get("digest")
        platform = manifest.get("platform") or {}
        annotations = manifest.get("annotations") or {}
        if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
            fail(f"invalid digest at descriptor {position}")
        if not isinstance(platform, dict) or not isinstance(annotations, dict):
            fail(f"invalid platform or annotations at descriptor {position}")

        if annotations.get("vnd.docker.reference.type") == "attestation-manifest":
            if platform != {"architecture": "unknown", "os": "unknown"}:
                fail("attestation platform must be exactly unknown/unknown")
            subject = annotations.get("vnd.docker.reference.digest")
            if not isinstance(subject, str) or not DIGEST.fullmatch(subject):
                fail("attestation subject missing or invalid")
            attestations.setdefault(subject, []).append(digest)
            continue

        key = (platform.get("os"), platform.get("architecture"))
        if key not in EXPECTED:
            fail(f"unexpected runnable platform {key[0]}/{key[1]}")
        variant = platform.get("variant")
        if key == ("linux", "amd64") and variant not in (None, ""):
            fail(f"unexpected amd64 variant {variant!r}")
        if key == ("linux", "arm64") and variant not in (None, "", "v8"):
            fail(f"unexpected arm64 variant {variant!r}")
        if key in runtime:
            fail(f"duplicate runtime platform {key[0]}/{key[1]}")
        runtime[key] = digest

    if set(runtime) != EXPECTED:
        fail("runtime platforms must be exactly linux/amd64 and linux/arm64")
    if set(attestations) != set(runtime.values()):
        fail("each and only each runtime manifest must have an attestation manifest")
    if any(len(values) != 1 for values in attestations.values()):
        fail("each runtime manifest must have exactly one attestation manifest")
    return {key[1]: runtime[key] for key in sorted(runtime)}


def main(argv: list[str] | None = None, stream: BinaryIO | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.parse_args(argv)
    result = validate_stream(stream or sys.stdin.buffer)
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
