#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
import tempfile
from pathlib import Path
from types import ModuleType

ROOT = Path(__file__).resolve().parent.parent


def load(name: str, relative: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {relative}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect_failure(callable_) -> None:
    try:
        result = callable_()
    except SystemExit as exc:
        if exc.code in (None, 0):
            raise AssertionError("expected a non-zero SystemExit") from exc
        return
    if isinstance(result, int) and result != 0:
        return
    raise AssertionError("expected policy failure")


def main() -> None:
    manifest = load("toroute_manifest_identity", "scripts/manifest-identity.py")
    attestation = load("toroute_attestation", "scripts/validate-attestation-data.py")
    vulnerabilities = load("toroute_vulnerabilities", "scripts/check-vulnerabilities.py")

    digest = lambda char: "sha256:" + char * 64
    amd, arm, aa, ab = (digest(char) for char in "abcd")
    index = {
        "manifests": [
            {"digest": amd, "platform": {"os": "linux", "architecture": "amd64"}},
            {"digest": arm, "platform": {"os": "linux", "architecture": "arm64"}},
            {"digest": aa, "platform": {"os": "unknown", "architecture": "unknown"}, "annotations": {"vnd.docker.reference.type": "attestation-manifest", "vnd.docker.reference.digest": amd}},
            {"digest": ab, "platform": {"os": "unknown", "architecture": "unknown"}, "annotations": {"vnd.docker.reference.type": "attestation-manifest", "vnd.docker.reference.digest": arm}},
        ]
    }
    assert manifest.validate_stream(io.BytesIO(json.dumps(index).encode())) == {"amd64": amd, "arm64": arm}
    bad_index = json.loads(json.dumps(index))
    bad_index["manifests"].append({"digest": digest("e"), "platform": {"os": "linux", "architecture": "386"}})
    expect_failure(lambda: manifest.validate_stream(io.BytesIO(json.dumps(bad_index).encode())))

    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        sbom = {"SPDXID": "SPDXRef-DOCUMENT", "name": "test", "packages": [{"name": "tor", "versionInfo": "0.4"}]}
        provenance = {"buildType": "https://mobyproject.org/buildkit@v1", "materials": [{"uri": "pkg:docker/docker/dockerfile@1"}], "invocation": {"parameters": {}}}
        paths = {}
        for name, value in (("sbom-amd64", sbom), ("sbom-arm64", sbom), ("provenance-amd64", provenance), ("provenance-arm64", provenance)):
            path = tmp / f"{name}.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            paths[name] = path
        summary = tmp / "attestation-summary.json"
        args = [
            "--sbom-amd64", str(paths["sbom-amd64"]), "--sbom-arm64", str(paths["sbom-arm64"]),
            "--provenance-amd64", str(paths["provenance-amd64"]), "--provenance-arm64", str(paths["provenance-arm64"]),
            "--summary", str(summary),
        ]
        assert attestation.main(args) == 0
        bad_sbom = tmp / "bad-sbom.json"
        bad_sbom.write_text(json.dumps({**sbom, "packages": []}), encoding="utf-8")
        bad_args = list(args)
        bad_args[bad_args.index(str(paths["sbom-amd64"]))] = str(bad_sbom)
        expect_failure(lambda: attestation.main(bad_args))

        clean = tmp / "clean.json"
        blocked = tmp / "blocked.json"
        clean.write_text(json.dumps({"Results": [{"Target": "debian", "Vulnerabilities": []}]}), encoding="utf-8")
        blocked.write_text(json.dumps({"Results": [{"Target": "debian", "Vulnerabilities": [{"VulnerabilityID": "CVE-2099-0001", "PkgName": "demo", "InstalledVersion": "1", "FixedVersion": "2", "Severity": "HIGH"}]}]}), encoding="utf-8")
        base = ["--date", "2026-07-20", "--exceptions", str(ROOT / "security/vulnerability-exceptions.json")]
        assert vulnerabilities.main([*base, "--report", f"linux/amd64={clean}", "--report", f"linux/arm64={clean}", "--evidence", str(tmp / "evidence.json")]) == 0
        expect_failure(lambda: vulnerabilities.main([*base, "--report", f"linux/386={clean}", "--evidence", str(tmp / "platform.json")]))
        assert vulnerabilities.main([*base, "--report", f"linux/amd64={blocked}", "--report", f"linux/arm64={clean}", "--evidence", str(tmp / "blocked-evidence.json")]) == 1
        expect_failure(lambda: vulnerabilities.main([*base, "--report", f"linux/amd64={clean}", "--evidence", str(tmp / "missing-platform.json")]))
    print("policy tooling tests passed")


if __name__ == "__main__":
    main()
