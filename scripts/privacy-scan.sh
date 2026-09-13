#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
patterns=(
  'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  'github_pat_[A-Za-z0-9_]+'
  'AKIA[0-9A-Z]{16}'
  'DOCKERHUB_TOKEN[[:space:]]*=[[:space:]]*[^$]'
  'D:\\work|/home/[A-Za-z0-9._-]+/|/Users/[A-Za-z0-9._-]+/'
  'kabu_manage|Proprien|Xserver'
)
for pattern in "${patterns[@]}"; do
  if grep -RInE --binary-files=without-match --exclude-dir=.git --exclude-dir=bin --exclude-dir=release --exclude-dir=.tmp-validation --exclude='*.sum' --exclude='privacy-scan.sh' "$pattern" .; then
    echo "privacy/secret scan matched: $pattern" >&2
    exit 1
  fi
done
# Real obfs4 lines should never be committed. Test fixtures are accepted only
# with RFC 5737 TEST-NET addresses and conspicuously fake certificate values.
python3 - <<'PYSCAN'
import ipaddress
import re
from pathlib import Path
pattern = re.compile(r"obfs4\s+([^\s:]+|\[[^]]+\]):([0-9]+)\s+([0-9A-Fa-f]{40})\s+cert=([^\s]+)")
allowed = [ipaddress.ip_network("192.0.2.0/24"), ipaddress.ip_network("198.51.100.0/24"), ipaddress.ip_network("203.0.113.0/24")]
for path in Path('.').rglob('*'):
    if not path.is_file() or any(part in {'.git','bin','release','.tmp-validation','__pycache__'} for part in path.parts):
        continue
    try:
        text = path.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    for match in pattern.finditer(text):
        host = match.group(1).strip('[]')
        cert = match.group(4)
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            raise SystemExit(f"possible real obfs4 bridge host in {path}: {host}")
        if not any(ip in network for network in allowed) or not cert.upper().startswith(('REDACT', 'REPLACE', 'TEST')):
            raise SystemExit(f"possible real obfs4 bridge line in {path}")
PYSCAN
echo 'privacy scan passed'
