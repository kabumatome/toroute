#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
owner=${1:?usage: prepare-release.sh GITHUB_OWNER}
owner_pattern='^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$'
[[ $owner =~ $owner_pattern ]] || { echo 'invalid GitHub owner' >&2; exit 1; }
OWNER_VALUE=$owner python3 - <<'PY'
import os
from pathlib import Path
owner = os.environ['OWNER_VALUE']
placeholder = 'OWNER' + '/toroute'
replacement = owner + '/toroute'
for path in Path('.').rglob('*'):
    if not path.is_file() or any(part in {'.git','bin','release','__pycache__'} for part in path.parts):
        continue
    try:
        text = path.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    updated = text.replace(placeholder, replacement)
    if updated != text:
        path.write_text(updated, encoding='utf-8')
remaining = []
for path in Path('.').rglob('*'):
    if not path.is_file() or any(part in {'.git','bin','release','__pycache__'} for part in path.parts):
        continue
    try:
        if placeholder in path.read_text(encoding='utf-8'):
            remaining.append(str(path))
    except (UnicodeDecodeError, OSError):
        pass
if remaining:
    raise SystemExit('placeholder remains in: ' + ', '.join(remaining))
PY
echo "prepared repository for ${owner}/toroute"
