#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for tag in v0.0.0 v1.0.0 v1.2.3-rc.1; do ./scripts/validate-release-tag.sh "$tag"; done
for tag in 1.0.0 v01.0.0 v1.0 v1.0.0+build v1.0.0-rc.01; do
  if ./scripts/validate-release-tag.sh "$tag" >/dev/null 2>&1; then
    echo "invalid tag accepted: $tag" >&2
    exit 1
  fi
done
if ./scripts/prepare-release.sh '-bad' >/dev/null 2>&1; then
  echo 'invalid owner accepted' >&2
  exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/prepare-release-fixture"
mkdir -p "$fixture/scripts" "$fixture/cmd/example" "$fixture/internal/example" "$fixture/.github/ISSUE_TEMPLATE"
cp scripts/prepare-release.sh "$fixture/scripts/prepare-release.sh"
placeholder='OWNER'/'toroute'
cat >"$fixture/go.mod" <<EOF_GO
module github.com/${placeholder}

go 1.23
EOF_GO
cat >"$fixture/cmd/example/main.go" <<EOF_GO
package main

import _ "github.com/${placeholder}/internal/example"

func main() {}
EOF_GO
cat >"$fixture/internal/example/example.go" <<'EOF_GO'
package example
EOF_GO
cat >"$fixture/README.md" <<EOF_MD
image: ghcr.io/${placeholder}:1.0.0
EOF_MD
cat >"$fixture/.github/ISSUE_TEMPLATE/config.yml" <<EOF_YML
contact_links:
  - name: Support policy
    url: https://github.com/${placeholder}/blob/main/SUPPORT.md
EOF_YML
(
  cd "$fixture"
  ./scripts/prepare-release.sh example-maintainer >/dev/null
  if grep -RIn --exclude-dir=.git "$placeholder" .; then
    echo 'repository owner placeholder remained' >&2
    exit 1
  fi
  grep -qx 'module github.com/example-maintainer/toroute' go.mod
  if grep -RIn --include='*.go' "github.com/${placeholder}" .; then
    echo 'old Go module path remained after owner preparation' >&2
    exit 1
  fi
  grep -RIl --include='*.go' 'github.com/example-maintainer/toroute' cmd internal | grep -q .
  grep -q 'ghcr.io/example-maintainer/toroute:1.0.0' README.md
  grep -q 'https://github.com/example-maintainer/toroute/blob/main/SUPPORT.md' .github/ISSUE_TEMPLATE/config.yml
)

prepared="$tmp/prepared-repo"
mkdir -p "$prepared"
tar --exclude=.git --exclude=bin --exclude=coverage.out --exclude=release --exclude=.tmp-validation -cf - . | tar -xf - -C "$prepared"
(
  cd "$prepared"
  placeholder='OWNER'/'toroute'
  if grep -RIn --exclude-dir=.git "$placeholder" .; then
    echo 'repository owner placeholder remained in prepared repository' >&2
    exit 1
  fi
  git init -q
  git config user.name 'Release Tool Test'
  git config user.email 'release-tool-test@example.invalid'
  git add .
  git commit -qm 'prepared release fixture'
  GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.0.0-rc.1 ./scripts/check-release-readiness.sh >/dev/null
  GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.0.0 ./scripts/check-release-readiness.sh >/dev/null
)

package_tmp=$(mktemp -d)
./scripts/package-source.sh 0.4.0-rc.12 "$package_tmp/release" >/dev/null
unzip -t "$package_tmp/release/toroute-0.4.0-rc.12-source.zip" >/dev/null
tar -tzf "$package_tmp/release/toroute-0.4.0-rc.12-source.tar.gz" >/dev/null
mkdir -p "$package_tmp/zip" "$package_tmp/tar"
unzip -q "$package_tmp/release/toroute-0.4.0-rc.12-source.zip" -d "$package_tmp/zip"
tar -xzf "$package_tmp/release/toroute-0.4.0-rc.12-source.tar.gz" -C "$package_tmp/tar"
diff -qr "$package_tmp/zip/toroute-0.4.0-rc.12-source" "$package_tmp/tar/toroute-0.4.0-rc.12-source" >/dev/null
python3 - "$package_tmp/zip/toroute-0.4.0-rc.12-source/SOURCE_METADATA.json" <<'PYMETA'
import json, re, sys
metadata=json.load(open(sys.argv[1], encoding='utf-8'))
assert metadata['schema_version'] == 1
assert metadata['project'] == 'ToRoute'
assert metadata['version'] == '0.4.0-rc.12'
assert re.fullmatch(r'[0-9a-f]{40}', metadata['source_commit'])
assert isinstance(metadata['source_date_epoch'], int) and metadata['source_date_epoch'] > 0
PYMETA
if find "$package_tmp/release" -name '__pycache__' -o -name '*.pyc' | grep -q .; then
  echo 'generated Python cache entered release output' >&2
  exit 1
fi
if ./scripts/package-source.sh 0.3.0 / >/dev/null 2>&1; then
  echo 'unsafe package output directory was accepted' >&2
  exit 1
fi
rm -rf "$package_tmp"
echo 'release tooling tests passed'
