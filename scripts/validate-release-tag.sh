#!/usr/bin/env bash
set -Eeuo pipefail
tag=${1:-}
if [[ ! $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$ ]]; then
  echo "tag is not an accepted SemVer release version: $tag" >&2
  exit 1
fi
prerelease=${BASH_REMATCH[5]:-}
if [[ -n $prerelease ]]; then
  IFS=. read -r -a identifiers <<<"$prerelease"
  for identifier in "${identifiers[@]}"; do
    if [[ $identifier =~ ^[0-9]+$ && ${#identifier} -gt 1 && $identifier == 0* ]]; then
      echo "numeric prerelease identifier has a leading zero: $tag" >&2
      exit 1
    fi
  done
fi
