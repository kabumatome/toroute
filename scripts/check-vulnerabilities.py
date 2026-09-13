#!/usr/bin/env python3
"""Apply ToRoute's strict, expiring HIGH/CRITICAL vulnerability policy."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
from pathlib import Path
from urllib.parse import urlparse

ALLOWED_PLATFORMS = {"linux/amd64", "linux/arm64"}
SAFE_TOKEN = re.compile(r"^[^\x00-\x1f\x7f]{1,256}$")
MAX_REPORT = 128 << 20


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", action="append", required=True, metavar="PLATFORM=FILE")
    parser.add_argument("--exceptions", default="security/vulnerability-exceptions.json")
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--date")
    args = parser.parse_args(argv)
    today = dt.date.fromisoformat(args.date) if args.date else dt.date.today()

    policy = json.loads(Path(args.exceptions).read_text(encoding="utf-8"))
    if policy.get("schemaVersion") != 1 or set(policy) != {"schemaVersion", "exceptions"}:
        raise SystemExit("vulnerability exception policy schema is invalid")
    raw_exceptions = policy["exceptions"]
    if not isinstance(raw_exceptions, list):
        raise SystemExit("exceptions must be a list")
    exceptions: dict[tuple[str, str, str], dict] = {}
    for number, item in enumerate(raw_exceptions, 1):
        required = {"vulnerability_id", "package", "platform", "expires", "reason", "tracking"}
        if not isinstance(item, dict) or set(item) != required:
            raise SystemExit(f"exception {number} fields are invalid")
        vulnerability_id = str(item["vulnerability_id"])
        package = str(item["package"])
        platform = str(item["platform"])
        if not SAFE_TOKEN.fullmatch(vulnerability_id) or not SAFE_TOKEN.fullmatch(package):
            raise SystemExit(f"exception {number} has an invalid ID or package")
        if platform not in ALLOWED_PLATFORMS:
            raise SystemExit(f"exception {number} has unsupported platform {platform!r}")
        key = (vulnerability_id, package, platform)
        if key in exceptions:
            raise SystemExit(f"duplicate exception {key}")
        expiry = dt.date.fromisoformat(str(item["expires"]))
        if expiry < today or expiry > today + dt.timedelta(days=90):
            raise SystemExit(f"invalid expiry for {key}: {expiry}")
        reason = str(item["reason"]).strip()
        if len(reason) < 20 or not SAFE_TOKEN.fullmatch(reason):
            raise SystemExit(f"reason is invalid or too short for {key}")
        tracking = str(item["tracking"]).strip()
        parsed = urlparse(tracking)
        if parsed.scheme != "https" or not parsed.netloc:
            raise SystemExit(f"tracking URL is invalid for {key}")
        normalized = dict(item)
        normalized["expires"] = expiry.isoformat()
        exceptions[key] = normalized

    findings: list[dict] = []
    seen_platforms: set[str] = set()
    for specification in args.report:
        if "=" not in specification:
            raise SystemExit(f"invalid report specification {specification!r}")
        platform, filename = specification.split("=", 1)
        if platform not in ALLOWED_PLATFORMS:
            raise SystemExit(f"unsupported scan platform {platform!r}")
        if platform in seen_platforms:
            raise SystemExit(f"duplicate scan report for {platform}")
        seen_platforms.add(platform)
        path = Path(filename)
        if path.stat().st_size > MAX_REPORT:
            raise SystemExit(f"scan report exceeds {MAX_REPORT} bytes: {path}")
        document = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise SystemExit(f"scan report is not an object: {path}")
        for result in document.get("Results") or []:
            if not isinstance(result, dict):
                raise SystemExit(f"scan result is not an object: {path}")
            for vulnerability in result.get("Vulnerabilities") or []:
                if not isinstance(vulnerability, dict):
                    raise SystemExit(f"vulnerability is not an object: {path}")
                severity = str(vulnerability.get("Severity", "")).upper()
                if severity not in {"HIGH", "CRITICAL"}:
                    continue
                vulnerability_id = str(vulnerability.get("VulnerabilityID", ""))
                package = str(vulnerability.get("PkgName", ""))
                if not SAFE_TOKEN.fullmatch(vulnerability_id) or not SAFE_TOKEN.fullmatch(package):
                    raise SystemExit(f"scan finding has an invalid ID or package in {path}")
                findings.append({
                    "platform": platform,
                    "target": str(result.get("Target", "")),
                    "vulnerability_id": vulnerability_id,
                    "package": package,
                    "installed_version": str(vulnerability.get("InstalledVersion", "")),
                    "fixed_version": str(vulnerability.get("FixedVersion", "")),
                    "severity": severity,
                })

    if seen_platforms != ALLOWED_PLATFORMS:
        missing = sorted(ALLOWED_PLATFORMS - seen_platforms)
        raise SystemExit("scan reports are required for both linux/amd64 and linux/arm64; missing: " + ", ".join(missing))

    blocked: list[dict] = []
    excepted: list[dict] = []
    used: set[tuple[str, str, str]] = set()
    for finding in findings:
        key = (finding["vulnerability_id"], finding["package"], finding["platform"])
        if key in exceptions:
            used.add(key)
            excepted.append({"finding": finding, "exception": exceptions[key]})
        else:
            blocked.append(finding)
    stale = set(exceptions) - used
    if stale:
        raise SystemExit("unused exceptions must be removed: " + repr(sorted(stale)))

    evidence = {
        "policy_date": today.isoformat(),
        "scanned_platforms": sorted(seen_platforms),
        "finding_count": len(findings),
        "excepted_count": len(excepted),
        "blocked_count": len(blocked),
        "excepted": excepted,
        "blocked": blocked,
    }
    Path(args.evidence).write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for finding in blocked:
        print("BLOCKED", finding["platform"], finding["severity"], finding["vulnerability_id"], finding["package"])
    return 1 if blocked else 0


if __name__ == "__main__":
    raise SystemExit(main())
