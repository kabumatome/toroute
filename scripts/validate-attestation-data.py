#!/usr/bin/env python3
"""Validate platform-specific BuildKit SBOM and provenance predicates."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

PLATFORMS = ("linux/amd64", "linux/arm64")


def load_object(path: str, label: str) -> dict:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"unable to read {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must be a JSON object")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    for platform in ("amd64", "arm64"):
        parser.add_argument(f"--sbom-{platform}", required=True)
        parser.add_argument(f"--provenance-{platform}", required=True)
    parser.add_argument("--summary", required=True)
    args = parser.parse_args(argv)

    summary: dict[str, dict] = {"sbom": {}, "provenance": {}}
    for short, platform in (("amd64", PLATFORMS[0]), ("arm64", PLATFORMS[1])):
        sbom = load_object(getattr(args, f"sbom_{short}"), f"{platform} SBOM")
        if sbom.get("SPDXID") != "SPDXRef-DOCUMENT":
            raise SystemExit(f"{platform} SBOM is not an SPDX document")
        packages = sbom.get("packages")
        if not isinstance(packages, list) or not packages:
            raise SystemExit(f"{platform} SBOM has no package inventory")
        if not any(isinstance(item, dict) and item.get("name") == "tor" for item in packages):
            raise SystemExit(f"{platform} SBOM does not contain the Tor package")
        summary["sbom"][platform] = {
            "document_name": str(sbom.get("name", "")),
            "package_count": len(packages),
            "contains_tor": True,
        }

        provenance = load_object(getattr(args, f"provenance_{short}"), f"{platform} provenance")
        build_type = provenance.get("buildType")
        materials = provenance.get("materials")
        if not isinstance(build_type, str) or "buildkit" not in build_type.lower():
            raise SystemExit(f"{platform} provenance has an unexpected buildType")
        if not isinstance(materials, list) or not materials:
            raise SystemExit(f"{platform} provenance has no materials")
        invocation = provenance.get("invocation")
        if not isinstance(invocation, dict):
            raise SystemExit(f"{platform} provenance has no invocation")
        summary["provenance"][platform] = {
            "build_type": build_type,
            "material_count": len(materials),
            "has_invocation": True,
        }

    Path(args.summary).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("SBOM and provenance data validated for linux/amd64 and linux/arm64")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
