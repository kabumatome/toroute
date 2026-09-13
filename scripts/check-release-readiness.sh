#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -d .git ]] || { echo 'release requires a Git repository' >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo 'release requires a clean working tree' >&2; git status --short >&2; exit 1; }
if [[ ${GITHUB_REF_TYPE:-} == tag ]]; then
  ./scripts/validate-release-tag.sh "${GITHUB_REF_NAME:-}"
  version=${GITHUB_REF_NAME#v}
  if [[ $version != *-* ]]; then
    python3 ./scripts/check-runtime-budget.py --validate-budget-only --require-baseline
  fi
fi
placeholder='OWNER'/'toroute'
if grep -RIn --exclude-dir=.git --exclude-dir=.tmp-validation "$placeholder" .; then echo 'OWNER placeholder remains' >&2; exit 1; fi
./scripts/privacy-scan.sh
