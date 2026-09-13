#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp=$(mktemp -d)
cleanup(){ rm -rf "$tmp"; }
trap cleanup EXIT

expect_rejection() {
  local expected=$1 path=$2 output rc=0
  output=$(./scripts/bridge-live-test.sh unused:image "$path" 2>&1) || rc=$?
  if (( rc == 0 )); then
    echo "Bridge harness unexpectedly accepted: $expected" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    echo "Bridge harness returned the wrong rejection for: $expected" >&2
    exit 1
  fi
}

expect_rejection 'Bridge input must be stored outside the Git repository' examples/bridges.txt.example

printf '%s\n' '# empty fixture' >"$tmp/target"
ln -s "$tmp/target" "$tmp/link"
expect_rejection 'Bridge input must be a regular non-symlink file' "$tmp/link"

: >"$tmp/empty"
expect_rejection 'Bridge input is empty' "$tmp/empty"

dd if=/dev/zero of="$tmp/oversized" bs=1048577 count=1 status=none
expect_rejection 'Bridge input exceeds 1048576 bytes' "$tmp/oversized"

echo 'Bridge live harness preflight tests passed'
