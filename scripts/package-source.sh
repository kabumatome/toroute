#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
raw_version=${1:?usage: package-source.sh VERSION [OUTPUT_DIR]}
version=${raw_version#v}
./scripts/validate-release-tag.sh "v${version}"
out=${2:-release}
[[ -n $out && $out != / && $out != . && $out != .. && $out != */../* && $out != ../* ]] || {
  echo "unsafe output directory: $out" >&2
  exit 1
}
name="toroute-${version}-source"
rm -rf -- "$out"
mkdir -p -- "$out"
out_abs=$(cd "$out" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/$name"
tar \
  --exclude=.git --exclude=bin --exclude=coverage.out --exclude=release --exclude=.tmp-validation \
  --exclude='validation-results' --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' \
  --exclude='*.zip' --exclude='*.tar.gz' --exclude='*.sha256' \
  -cf - . | tar -xf - -C "$tmp/$name"

source_commit=''
source_epoch='0'
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  source_commit=$(git rev-parse HEAD)
  source_epoch=$(git show -s --format=%ct HEAD)
elif [[ -f SOURCE_METADATA.json ]]; then
  source_commit=$(python3 -c 'import json; print(json.load(open("SOURCE_METADATA.json", encoding="utf-8"))["source_commit"])')
  source_epoch=$(python3 -c 'import json; print(json.load(open("SOURCE_METADATA.json", encoding="utf-8"))["source_date_epoch"])')
fi
if [[ $source_commit =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  python3 - "$tmp/$name/SOURCE_METADATA.json" "$version" "$source_commit" "$source_epoch" <<'PYMETA'
import json
import sys
from pathlib import Path

output, version, commit, epoch = sys.argv[1:]
data = {
    "schema_version": 1,
    "project": "ToRoute",
    "version": version,
    "source_commit": commit.lower(),
    "source_date_epoch": int(epoch),
}
Path(output).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYMETA
fi
TZ=UTC find "$tmp/$name" -exec touch -h -d '@0' {} +
(
  cd "$tmp"
  tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' \
    -czf "$out_abs/$name.tar.gz" "$name"
)
python3 - "$tmp" "$name" "$out_abs/$name.zip" <<'PY'
import os
import stat
import sys
import zipfile

root, name, output = sys.argv[1:]
base = os.path.join(root, name)
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for directory, directories, files in os.walk(base, followlinks=False):
        directories.sort()
        files.sort()
        directory_mode = os.lstat(directory).st_mode
        if not stat.S_ISDIR(directory_mode):
            raise SystemExit(f"non-directory source entry is unsupported: {directory}")
        directory_arcname = os.path.relpath(directory, root).replace(os.sep, "/") + "/"
        directory_info = zipfile.ZipInfo(directory_arcname, (1980, 1, 1, 0, 0, 0))
        directory_info.create_system = 3
        directory_info.external_attr = ((directory_mode & 0xFFFF) << 16) | 0x10
        archive.writestr(directory_info, b"")
        for child in directories:
            child_path = os.path.join(directory, child)
            if not stat.S_ISDIR(os.lstat(child_path).st_mode):
                raise SystemExit(f"non-directory source entry is unsupported: {child_path}")
        for filename in files:
            path = os.path.join(directory, filename)
            mode = os.lstat(path).st_mode
            if not stat.S_ISREG(mode):
                raise SystemExit(f"non-regular source entry is unsupported: {path}")
            arcname = os.path.relpath(path, root).replace(os.sep, "/")
            info = zipfile.ZipInfo(arcname, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (mode & 0xFFFF) << 16
            with open(path, "rb") as handle:
                archive.writestr(
                    info,
                    handle.read(),
                    compress_type=zipfile.ZIP_DEFLATED,
                    compresslevel=6,
                )
PY
(
  cd "$out_abs"
  sha256sum "$name.tar.gz" "$name.zip" >SHA256SUMS
)
echo "packaged $name"
