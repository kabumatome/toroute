#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

packages=(
  ./cmd/toroute
  ./internal/config
  ./internal/control
  ./internal/render
  ./internal/runtime
  ./internal/supervisor
  ./tests/netprobe
  ./tests/proxycheck
)

jobs=${GO_TEST_JOBS:-1}
max_procs=${GO_TEST_GOMAXPROCS:-2}
case "$jobs" in ''|*[!0-9]*) echo 'GO_TEST_JOBS must be a positive integer' >&2; exit 1;; esac
case "$max_procs" in ''|*[!0-9]*) echo 'GO_TEST_GOMAXPROCS must be a positive integer' >&2; exit 1;; esac
(( jobs > 0 && max_procs > 0 )) || { echo 'Go test limits must be positive' >&2; exit 1; }

coverage_dir=$(mktemp -d)
trap 'rm -rf "$coverage_dir"' EXIT

for package in "${packages[@]}"; do
  name=${package#./}
  name=${name//\//_}
  echo "==> go test -race $package"
  GOMAXPROCS=$max_procs timeout --kill-after=5s 120s \
    go test -race -count=1 -timeout=90s -p="$jobs" \
    -coverprofile="$coverage_dir/${name}.out" "$package"
done

TOROUTE_COVERAGE_DIR="$coverage_dir" python3 - <<'PY'
from pathlib import Path
import os
parts = sorted(Path(os.environ['TOROUTE_COVERAGE_DIR']).glob('*.out'))
if not parts:
    raise SystemExit('no coverage profiles were generated')
mode = None
lines = []
for path in parts:
    content = path.read_text(encoding='utf-8').splitlines()
    if not content or not content[0].startswith('mode: '):
        raise SystemExit(f'invalid coverage profile: {path}')
    current = content[0]
    if mode is None:
        mode = current
    elif current != mode:
        raise SystemExit('coverage modes differ')
    lines.extend(content[1:])
Path('coverage.out').write_text('\n'.join([mode, *lines]) + '\n', encoding='utf-8')
PY

go tool cover -func=coverage.out | tail -n 1
