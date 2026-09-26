#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

required=(
  go.mod Dockerfile compose.yml Makefile .gitattributes RUN_DOCKER_VALIDATION.cmd LICENSE NOTICE THIRD_PARTY_NOTICES.md
  README.md README.ja.md SECURITY.md SUPPORT.md CONTRIBUTING.md CODE_OF_CONDUCT.md CHANGELOG.md
  docs/README.md docs/core/REQUIREMENTS_AND_DESIGN_JA.md docs/core/ARCHITECTURE.md docs/core/CONFIGURATION.md
  docs/core/THREAT_MODEL.md docs/core/MIGRATION_DPERSON.md docs/validation/TEST_STRATEGY.md
  docs/release/RELEASE_CRITERIA.md docs/release/MAINTAINER_RELEASE_GUIDE_JA.md docs/history/RECOVERY_REPORT_JA.md
  docs/history/VALIDATION_REPORT_JA.md docs/core/NAMING.md docs/references/SOURCES.md docs/release/BASE_IMAGE_DECISION.md
  docs/validation/DOCKER_VALIDATION_WINDOWS_JA.md docs/history/CONTAINER_RC_EVIDENCE_JA.md docs/validation/LOCAL_FULL_VALIDATION_JA.md
  docs/evidence/rc10-windows-docker-public-summary.json
  docs/evidence/rc12-windows-docker-public-summary.json
  scripts/privacy-scan.sh scripts/validate-release-tag.sh scripts/prepare-release.sh
  scripts/test-release-tools.sh scripts/check-release-readiness.sh scripts/package-source.sh
  scripts/docker-config-test.sh scripts/live-smoke.sh scripts/compose-network-test.sh scripts/docker-child-failure-test.sh scripts/bridge-live-test.sh scripts/test-bridge-live-harness.sh
  scripts/manifest-identity.py scripts/validate-attestation-data.py scripts/check-vulnerabilities.py scripts/test-policy-tools.sh scripts/test-policy-tools.py
  scripts/image-inventory.sh scripts/collect-running-metrics.sh scripts/runtime-benchmark.sh
  scripts/check-runtime-budget.py scripts/test-runtime-budget.py scripts/test-go.sh scripts/validate-source.py
  scripts/check-validation-environment.sh
  scripts/check-windows-validation.py scripts/sanitize-validation-evidence.py
  scripts/test-sanitize-validation-evidence.py
  tools/windows/Run-ToRoute-Docker-Validation.ps1 tools/windows/Run-ToRoute-Docker-Validation.cmd
  tests/docker-validation.yml tests/netprobe/main.go tests/proxycheck/main.go
  .github/workflows/ci.yml .github/workflows/codeql.yml .github/workflows/scheduled-live.yml
  .github/workflows/bootstrap-ghcr.yml .github/workflows/release.yml .github/dependabot.yml
  .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/config.yml
  security/vulnerability-exceptions.json security/runtime-budgets.json security/runtime-baseline-full-http-amd64.json
)
for path in "${required[@]}"; do
  [[ -f $path ]] || { echo "missing required file: $path" >&2; exit 1; }
done

# SOURCE_METADATA.json belongs only to generated source archives. A tracked,
# stale copy can misrepresent the source commit and release identity.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
   git ls-files --error-unmatch SOURCE_METADATA.json >/dev/null 2>&1; then
  echo 'SOURCE_METADATA.json must not be tracked in a Git checkout' >&2
  exit 1
fi

# The public source must use the current name and must not expose removed escape hatches.
if grep -RInE --binary-files=without-match --exclude-dir=.git --exclude-dir=bin --exclude-dir=release --exclude-dir=.tmp-validation --exclude='validate-repository.sh' \
  'HushRoute|torproxy-modern|HUSHROUTE_|TOROUTE_ALLOW_UNSAFE|ALLOW_UNSAFE_TORRC' .; then
  echo 'old project name or removed unsafe configuration remains' >&2
  exit 1
fi
# Historical product references are permitted only in migration/source documentation.
if grep -RIl --binary-files=without-match --exclude-dir=.git --exclude-dir=bin --exclude-dir=release --exclude-dir=.tmp-validation --exclude='validate-repository.sh' \
  'dperson/torproxy' . | grep -Ev '^(./docs/core/(MIGRATION_DPERSON|REQUIREMENTS_AND_DESIGN_JA)\.md|./docs/references/SOURCES\.md|./docs/history/RECOVERY_REPORT_JA\.md|./docs/release/BASE_IMAGE_DECISION\.md|./README(\.ja)?\.md|./NOTICE)
  echo 'dperson/torproxy reference exists outside approved migration documentation' >&2
  exit 1
fi

# Keep the docs root as an index only; current, operational, and historical material
# belongs in the purpose-specific subdirectories.
unexpected_docs=$(find docs -maxdepth 1 -type f -name '*.md' ! -name README.md -print)
if [[ -n $unexpected_docs ]]; then
  echo 'Markdown files must not be added directly under docs/ except docs/README.md:' >&2
  printf '%s\n' "$unexpected_docs" >&2
  exit 1
fi

# Static container boundaries.
grep -q "^USER \${UID}:\${GID}$" Dockerfile
grep -q '^EXPOSE 9050$' Dockerfile
if grep -qE '^EXPOSE .*8118|EXPOSE .*9051' Dockerfile; then
  echo 'Dockerfile must not expose HTTP or control ports by default' >&2
  exit 1
fi
grep -q 'tor-geoipdb' Dockerfile
grep -q 'adduser' Dockerfile
if grep -q 'adduser ca-certificates' Dockerfile; then
  echo 'runtime image must not install the redundant ca-certificates package' >&2
  exit 1
fi
grep -q 'COPY LICENSE NOTICE THIRD_PARTY_NOTICES.md /usr/share/doc/toroute/' Dockerfile
grep -q 'HEALTHCHECK' Dockerfile
grep -q -- '--start-period=420s' Dockerfile
grep -q -- '--start-interval=5s' Dockerfile
grep -q -- '--interval=30s' Dockerfile
grep -q 'Wait-DockerHealthSynchronization' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'docker-health-sync.jsonl' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'TimeoutSeconds 45' tools/windows/Run-ToRoute-Docker-Validation.ps1
[[ $(grep -c '^COPY go.mod ./\?$' Dockerfile) -ge 3 ]] || { echo 'all Go build stages must receive go.mod' >&2; exit 1; }
grep -q '^FROM scratch AS netprobe$' Dockerfile
grep -q '^FROM scratch AS proxycheck$' Dockerfile
grep -q "^FROM debian:\${DEBIAN_VERSION} AS runtime$" Dockerfile
grep -q 'COPY tests/proxycheck ./tests/proxycheck' Dockerfile
grep -q 'cap_drop:' compose.yml
grep -qE 'cap_drop:.*ALL|- ALL' compose.yml
grep -q 'no-new-privileges:true' compose.yml
grep -q 'read_only: true' compose.yml
grep -q 'internal: true' compose.yml
grep -q 'gw_priority: 1' compose.yml
if grep -qE '(^|[[:space:]])ports:' compose.yml; then
  echo 'compose.yml must not publish host ports by default' >&2
  exit 1
fi

# Windows Docker validation must remain one-command, evidence-producing, and dependency-light.
grep -q 'Run-ToRoute-Docker-Validation.ps1' tools/windows/Run-ToRoute-Docker-Validation.cmd
grep -q 'Docker Compose 2.33.1' docs/validation/DOCKER_VALIDATION_WINDOWS_JA.md
grep -q 'ToRoute-Docker-Validation-' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'SOCKS5 remote DNS' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'HTTP CONNECT' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'arm64 QEMU' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'Compress-Archive' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'proxycheck' tests/docker-validation.yml
grep -q 'gw_priority: 1' tests/docker-validation.yml

# Generated Tor safety defaults must remain present.
grep -q 'ClientOnly 1' internal/render/render.go
grep -q 'ControlPort 0' internal/render/render.go
grep -q 'CookieAuthentication 1' internal/render/render.go
grep -q 'SafeLogging 1' internal/render/render.go
grep -q 'SafeSocks 1' internal/render/render.go
grep -q 'IsolateClientAddr IsolateSOCKSAuth' internal/render/render.go
# check-config must use the explicitly writable runtime tmpfs, never system /tmp.
grep -Fq 'os.MkdirTemp(cfg.RuntimeDir, ".check-*")' internal/runtime/runtime.go
if grep -Fq 'os.MkdirTemp("", "toroute-check-*")' internal/runtime/runtime.go; then
  echo 'check-config must not use the system temporary directory' >&2
  exit 1
fi

for file in scripts/*.sh; do bash -n "$file"; done
python3 -m py_compile scripts/*.py
python3 ./scripts/check-windows-validation.py
python3 ./scripts/test-sanitize-validation-evidence.py
python3 - <<'PY'
import json
import re
from pathlib import Path
import yaml

workflow_paths = sorted(Path('.github/workflows').glob('*.yml'))
for path in workflow_paths:
    doc = yaml.safe_load(path.read_text(encoding='utf-8'))
    if doc.get('permissions') != {}:
        raise SystemExit(f'{path}: top-level permissions must be empty')
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        match = re.search(r'\buses:\s*([^\s#]+)', line)
        if not match:
            continue
        action = match.group(1)
        if action.startswith('./'):
            continue
        if not re.search(r'@[0-9a-f]{40}$', action):
            raise SystemExit(f'{path}:{number}: action is not pinned to a full SHA: {action}')


for workflow in ['.github/workflows/release.yml', '.github/workflows/bootstrap-ghcr.yml']:
    text = Path(workflow).read_text(encoding='utf-8')
    if 'python3-yaml shellcheck' not in text:
        raise SystemExit(f'{workflow}: repository policy requires python3-yaml')

release = Path('.github/workflows/release.yml').read_text(encoding='utf-8')
required_release_fragments = [
    'Build and push one candidate to all configured registries',
    'Resolve registry-local candidate identities',
    'manifest-identity.py',
    'Extract and validate candidate SBOM and provenance',
    'Record exact amd64 image footprint and package inventory',
    'validate-attestation-data.py',
    'Scan amd64 candidate',
    'Scan arm64 candidate',
    'check-vulnerabilities.py',
    'Prove exact tags are unused',
    'Promote exact tags within each registry',
    'Verify exact tags and update stable aliases',
    'Verify anonymous public tags and candidate identity',
    'Create or verify draft Release',
]
for fragment in required_release_fragments:
    if fragment not in release:
        raise SystemExit(f'release workflow is missing safety control: {fragment}')
if release.count("vars.TOROUTE_RELEASES_ENABLED == 'true'") != 2:
    raise SystemExit('release workflow must guard verification and publication with the explicit release-enable variable')
if 'release tag must point to the current main commit' not in release:
    raise SystemExit('release workflow must reject tags that do not point to current main')
if release.count('docker/build-push-action@') != 1:
    raise SystemExit('release workflow must build the release candidate exactly once')
if 'imagetools create --tag "$DOCKER_EXACT" "$DOCKER_CANDIDATE@$DOCKER_DIGEST"' not in release:
    raise SystemExit('Docker Hub exact tag must be promoted from its registry-local candidate')
if 'imagetools create --tag "$GHCR_EXACT" "$GHCR_CANDIDATE@$GHCR_DIGEST"' not in release:
    raise SystemExit('GHCR exact tag must be promoted from its registry-local candidate')
if 'aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0' not in release:
    raise SystemExit('release workflow does not use the reviewed Trivy Action commit')
if release.count('version: v0.72.0') != 2:
    raise SystemExit('release workflow must pin Trivy v0.72.0 for both platform scans')
if 'make validate-build' not in release:
    raise SystemExit('release workflow does not perform native and arm64 source builds')
if 'LIVE_METRICS_OUTPUT: release-evidence/runtime-metrics-amd64.json' not in release:
    raise SystemExit('release workflow does not retain runtime metrics')
if 'check-runtime-budget.py' not in Path('scripts/collect-running-metrics.sh').read_text(encoding='utf-8'):
    raise SystemExit('runtime metrics are not checked against the budget policy')

bootstrap = Path('.github/workflows/bootstrap-ghcr.yml').read_text(encoding='utf-8')
for fragment in ['platforms: linux/amd64,linux/arm64', 'Record amd64 image footprint and package inventory', 'version: v0.72.0', 'provenance: mode=max', 'sbom: true', 'manifest-identity.py', 'Extract and validate bootstrap SBOM and provenance', 'validate-attestation-data.py', 'Validate amd64 live Tor paths and collect runtime metrics', 'runtime-metrics-amd64.json', 'Scan amd64 bootstrap candidate', 'Scan arm64 bootstrap candidate', 'check-vulnerabilities.py', 'Upload bootstrap evidence']:
    if fragment not in bootstrap:
        raise SystemExit(f'bootstrap workflow is missing: {fragment}')

if 'TOROUTE_METRICS_PROFILE=full-http' not in Path('scripts/live-smoke.sh').read_text(encoding='utf-8'):
    raise SystemExit('live runtime evidence must identify the full-http profile')
runtime_budget = __import__('json').loads(Path('security/runtime-budgets.json').read_text(encoding='utf-8'))
required_budget_keys = {'schema_version', 'status', 'max_image_size_bytes', 'max_package_count', 'max_bootstrap_milliseconds', 'max_steady_memory_bytes', 'max_idle_cpu_usec_per_second', 'max_pids', 'notes'}
if set(runtime_budget) != required_budget_keys or runtime_budget['schema_version'] != 1 or runtime_budget['status'] != 'active':
    raise SystemExit('runtime budget configuration must be active and have the reviewed schema')
baseline = __import__('json').loads(Path('security/runtime-baseline-full-http-amd64.json').read_text(encoding='utf-8'))
if baseline.get('schema_version') != 1 or baseline.get('profile') != 'full-http' or baseline.get('validation_checks_passed') != 12:
    raise SystemExit('reviewed runtime baseline is invalid')

evidence_expectations = {
    'docs/evidence/rc10-windows-docker-public-summary.json': ('0.4.0-rc.10', False, None),
    'docs/evidence/rc12-windows-docker-public-summary.json': (
        '0.4.0-rc.12',
        True,
        '09340692f842bfccd34b3b8f38b4d1ee25a5ef21',
    ),
}
for path, (version, eligible, revision) in evidence_expectations.items():
    summary = json.loads(Path(path).read_text(encoding='utf-8'))
    checks = summary.get('validation', {}).get('checks', [])
    publication = summary.get('publication', {})
    source = summary.get('source', {})
    if (
        summary.get('schema_version') != 1
        or summary.get('toroute_version') != version
        or summary.get('validation', {}).get('succeeded') is not True
        or len(checks) != 12
        or any(item.get('status') != 'passed' for item in checks)
        or summary.get('runtime_budget', {}).get('passed') is not True
        or summary.get('release_gate_eligible') is not eligible
        or publication.get('raw_evidence_publishable') is not False
        or publication.get('this_summary_contains_raw_operational_data') is not False
        or source.get('revision') != revision
    ):
        raise SystemExit(f'public validation evidence contract failed: {path}')

source_validation = Path('scripts/validate-source.py').read_text(encoding='utf-8')
if '"-lc"' in source_validation:
    raise SystemExit('source validation must not use a login shell that can replace the toolchain PATH')

ci = Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
codeql = Path('.github/workflows/codeql.yml').read_text(encoding='utf-8')
scheduled_live = Path('.github/workflows/scheduled-live.yml').read_text(encoding='utf-8')
if 'workflow_dispatch:' not in ci or "paths-ignore: ['**/*.md']" not in ci:
    raise SystemExit('CI must support deliberate manual runs and skip documentation-only changes')
actionlint_install = 'go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12'
for workflow_name, workflow_text in (
    ('CI', ci),
    ('release', release),
    ('bootstrap', bootstrap),
):
    if actionlint_install not in workflow_text or 'run: actionlint' not in workflow_text:
        raise SystemExit(f'{workflow_name} workflow must install pinned actionlint and run it')
if ".github/workflows/codeql.yml" not in codeql:
    raise SystemExit('CodeQL workflow changes must trigger CodeQL validation')
if 'schedule:' in codeql or 'schedule:' in scheduled_live:
    raise SystemExit('CodeQL and live-network workflows must remain manual-only to control Actions usage')

policy = yaml.safe_load(Path('.github/dependabot.yml').read_text(encoding='utf-8'))
if not isinstance(policy, dict):
    raise SystemExit('dependabot configuration is invalid')
ecosystems = {item.get('package-ecosystem') for item in policy.get('updates', []) if isinstance(item, dict)}
if not {'github-actions', 'gomod', 'docker'} <= ecosystems:
    raise SystemExit('Dependabot must cover GitHub Actions, Go modules, and Docker')
print('workflow and repository policy checks passed')
PY

# Bridge live validation must preserve the secret boundary and cleanup lifecycle.
grep -Fq "Bridge input must be stored outside the Git repository" scripts/bridge-live-test.sh
grep -Fq "The secret travels only over stdin" scripts/bridge-live-test.sh
grep -Fq "docker volume rm -f" scripts/bridge-live-test.sh
grep -Fq "logs suppressed to protect Bridge data" scripts/bridge-live-test.sh
grep -Fq "target=/run/bridge-input,readonly" scripts/bridge-live-test.sh

echo 'repository validation passed'
; then
  echo 'dperson/torproxy reference exists outside approved migration documentation' >&2
  exit 1
fi

# Keep the docs root as an index only; current, operational, and historical material
# belongs in the purpose-specific subdirectories.
unexpected_docs=$(find docs -maxdepth 1 -type f -name '*.md' ! -name README.md -print)
if [[ -n $unexpected_docs ]]; then
  echo 'Markdown files must not be added directly under docs/ except docs/README.md:' >&2
  printf '%s\n' "$unexpected_docs" >&2
  exit 1
fi

# Static container boundaries.
grep -q "^USER \${UID}:\${GID}$" Dockerfile
grep -q '^EXPOSE 9050$' Dockerfile
if grep -qE '^EXPOSE .*8118|EXPOSE .*9051' Dockerfile; then
  echo 'Dockerfile must not expose HTTP or control ports by default' >&2
  exit 1
fi
grep -q 'tor-geoipdb' Dockerfile
grep -q 'adduser' Dockerfile
if grep -q 'adduser ca-certificates' Dockerfile; then
  echo 'runtime image must not install the redundant ca-certificates package' >&2
  exit 1
fi
grep -q 'COPY LICENSE NOTICE THIRD_PARTY_NOTICES.md /usr/share/doc/toroute/' Dockerfile
grep -q 'HEALTHCHECK' Dockerfile
grep -q -- '--start-period=420s' Dockerfile
grep -q -- '--start-interval=5s' Dockerfile
grep -q -- '--interval=30s' Dockerfile
grep -q 'Wait-DockerHealthSynchronization' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'docker-health-sync.jsonl' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'TimeoutSeconds 45' tools/windows/Run-ToRoute-Docker-Validation.ps1
[[ $(grep -c '^COPY go.mod ./\?$' Dockerfile) -ge 3 ]] || { echo 'all Go build stages must receive go.mod' >&2; exit 1; }
grep -q '^FROM scratch AS netprobe$' Dockerfile
grep -q '^FROM scratch AS proxycheck$' Dockerfile
grep -q "^FROM debian:\${DEBIAN_VERSION} AS runtime$" Dockerfile
grep -q 'COPY tests/proxycheck ./tests/proxycheck' Dockerfile
grep -q 'cap_drop:' compose.yml
grep -qE 'cap_drop:.*ALL|- ALL' compose.yml
grep -q 'no-new-privileges:true' compose.yml
grep -q 'read_only: true' compose.yml
grep -q 'internal: true' compose.yml
grep -q 'gw_priority: 1' compose.yml
if grep -qE '(^|[[:space:]])ports:' compose.yml; then
  echo 'compose.yml must not publish host ports by default' >&2
  exit 1
fi

# Windows Docker validation must remain one-command, evidence-producing, and dependency-light.
grep -q 'Run-ToRoute-Docker-Validation.ps1' tools/windows/Run-ToRoute-Docker-Validation.cmd
grep -q 'Docker Compose 2.33.1' docs/validation/DOCKER_VALIDATION_WINDOWS_JA.md
grep -q 'ToRoute-Docker-Validation-' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'SOCKS5 remote DNS' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'HTTP CONNECT' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'arm64 QEMU' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'Compress-Archive' tools/windows/Run-ToRoute-Docker-Validation.ps1
grep -q 'proxycheck' tests/docker-validation.yml
grep -q 'gw_priority: 1' tests/docker-validation.yml

# Generated Tor safety defaults must remain present.
grep -q 'ClientOnly 1' internal/render/render.go
grep -q 'ControlPort 0' internal/render/render.go
grep -q 'CookieAuthentication 1' internal/render/render.go
grep -q 'SafeLogging 1' internal/render/render.go
grep -q 'SafeSocks 1' internal/render/render.go
grep -q 'IsolateClientAddr IsolateSOCKSAuth' internal/render/render.go
# check-config must use the explicitly writable runtime tmpfs, never system /tmp.
grep -Fq 'os.MkdirTemp(cfg.RuntimeDir, ".check-*")' internal/runtime/runtime.go
if grep -Fq 'os.MkdirTemp("", "toroute-check-*")' internal/runtime/runtime.go; then
  echo 'check-config must not use the system temporary directory' >&2
  exit 1
fi

for file in scripts/*.sh; do bash -n "$file"; done
python3 -m py_compile scripts/*.py
python3 ./scripts/check-windows-validation.py
python3 ./scripts/test-sanitize-validation-evidence.py
python3 - <<'PY'
import json
import re
from pathlib import Path
import yaml

workflow_paths = sorted(Path('.github/workflows').glob('*.yml'))
for path in workflow_paths:
    doc = yaml.safe_load(path.read_text(encoding='utf-8'))
    if doc.get('permissions') != {}:
        raise SystemExit(f'{path}: top-level permissions must be empty')
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        match = re.search(r'\buses:\s*([^\s#]+)', line)
        if not match:
            continue
        action = match.group(1)
        if action.startswith('./'):
            continue
        if not re.search(r'@[0-9a-f]{40}$', action):
            raise SystemExit(f'{path}:{number}: action is not pinned to a full SHA: {action}')


for workflow in ['.github/workflows/release.yml', '.github/workflows/bootstrap-ghcr.yml']:
    text = Path(workflow).read_text(encoding='utf-8')
    if 'python3-yaml shellcheck' not in text:
        raise SystemExit(f'{workflow}: repository policy requires python3-yaml')

release = Path('.github/workflows/release.yml').read_text(encoding='utf-8')
required_release_fragments = [
    'Build and push one candidate to all configured registries',
    'Resolve registry-local candidate identities',
    'manifest-identity.py',
    'Extract and validate candidate SBOM and provenance',
    'Record exact amd64 image footprint and package inventory',
    'validate-attestation-data.py',
    'Scan amd64 candidate',
    'Scan arm64 candidate',
    'check-vulnerabilities.py',
    'Prove exact tags are unused',
    'Promote exact tags within each registry',
    'Verify exact tags and update stable aliases',
    'Verify anonymous public tags and candidate identity',
    'Create or verify draft Release',
]
for fragment in required_release_fragments:
    if fragment not in release:
        raise SystemExit(f'release workflow is missing safety control: {fragment}')
if release.count("vars.TOROUTE_RELEASES_ENABLED == 'true'") != 2:
    raise SystemExit('release workflow must guard verification and publication with the explicit release-enable variable')
if 'release tag must point to the current main commit' not in release:
    raise SystemExit('release workflow must reject tags that do not point to current main')
if release.count('docker/build-push-action@') != 1:
    raise SystemExit('release workflow must build the release candidate exactly once')
if 'imagetools create --tag "$DOCKER_EXACT" "$DOCKER_CANDIDATE@$DOCKER_DIGEST"' not in release:
    raise SystemExit('Docker Hub exact tag must be promoted from its registry-local candidate')
if 'imagetools create --tag "$GHCR_EXACT" "$GHCR_CANDIDATE@$GHCR_DIGEST"' not in release:
    raise SystemExit('GHCR exact tag must be promoted from its registry-local candidate')
if 'aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0' not in release:
    raise SystemExit('release workflow does not use the reviewed Trivy Action commit')
if release.count('version: v0.72.0') != 2:
    raise SystemExit('release workflow must pin Trivy v0.72.0 for both platform scans')
if 'make validate-build' not in release:
    raise SystemExit('release workflow does not perform native and arm64 source builds')
if 'LIVE_METRICS_OUTPUT: release-evidence/runtime-metrics-amd64.json' not in release:
    raise SystemExit('release workflow does not retain runtime metrics')
if 'check-runtime-budget.py' not in Path('scripts/collect-running-metrics.sh').read_text(encoding='utf-8'):
    raise SystemExit('runtime metrics are not checked against the budget policy')

bootstrap = Path('.github/workflows/bootstrap-ghcr.yml').read_text(encoding='utf-8')
for fragment in ['platforms: linux/amd64,linux/arm64', 'Record amd64 image footprint and package inventory', 'version: v0.72.0', 'provenance: mode=max', 'sbom: true', 'manifest-identity.py', 'Extract and validate bootstrap SBOM and provenance', 'validate-attestation-data.py', 'Validate amd64 live Tor paths and collect runtime metrics', 'runtime-metrics-amd64.json', 'Scan amd64 bootstrap candidate', 'Scan arm64 bootstrap candidate', 'check-vulnerabilities.py', 'Upload bootstrap evidence']:
    if fragment not in bootstrap:
        raise SystemExit(f'bootstrap workflow is missing: {fragment}')

if 'TOROUTE_METRICS_PROFILE=full-http' not in Path('scripts/live-smoke.sh').read_text(encoding='utf-8'):
    raise SystemExit('live runtime evidence must identify the full-http profile')
runtime_budget = __import__('json').loads(Path('security/runtime-budgets.json').read_text(encoding='utf-8'))
required_budget_keys = {'schema_version', 'status', 'max_image_size_bytes', 'max_package_count', 'max_bootstrap_milliseconds', 'max_steady_memory_bytes', 'max_idle_cpu_usec_per_second', 'max_pids', 'notes'}
if set(runtime_budget) != required_budget_keys or runtime_budget['schema_version'] != 1 or runtime_budget['status'] != 'active':
    raise SystemExit('runtime budget configuration must be active and have the reviewed schema')
baseline = __import__('json').loads(Path('security/runtime-baseline-full-http-amd64.json').read_text(encoding='utf-8'))
if baseline.get('schema_version') != 1 or baseline.get('profile') != 'full-http' or baseline.get('validation_checks_passed') != 12:
    raise SystemExit('reviewed runtime baseline is invalid')

evidence_expectations = {
    'docs/evidence/rc10-windows-docker-public-summary.json': ('0.4.0-rc.10', False, None),
    'docs/evidence/rc12-windows-docker-public-summary.json': (
        '0.4.0-rc.12',
        True,
        '09340692f842bfccd34b3b8f38b4d1ee25a5ef21',
    ),
}
for path, (version, eligible, revision) in evidence_expectations.items():
    summary = json.loads(Path(path).read_text(encoding='utf-8'))
    checks = summary.get('validation', {}).get('checks', [])
    publication = summary.get('publication', {})
    source = summary.get('source', {})
    if (
        summary.get('schema_version') != 1
        or summary.get('toroute_version') != version
        or summary.get('validation', {}).get('succeeded') is not True
        or len(checks) != 12
        or any(item.get('status') != 'passed' for item in checks)
        or summary.get('runtime_budget', {}).get('passed') is not True
        or summary.get('release_gate_eligible') is not eligible
        or publication.get('raw_evidence_publishable') is not False
        or publication.get('this_summary_contains_raw_operational_data') is not False
        or source.get('revision') != revision
    ):
        raise SystemExit(f'public validation evidence contract failed: {path}')

source_validation = Path('scripts/validate-source.py').read_text(encoding='utf-8')
if '"-lc"' in source_validation:
    raise SystemExit('source validation must not use a login shell that can replace the toolchain PATH')

ci = Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
codeql = Path('.github/workflows/codeql.yml').read_text(encoding='utf-8')
scheduled_live = Path('.github/workflows/scheduled-live.yml').read_text(encoding='utf-8')
if 'workflow_dispatch:' not in ci or "paths-ignore: ['**/*.md']" not in ci:
    raise SystemExit('CI must support deliberate manual runs and skip documentation-only changes')
actionlint_install = 'go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12'
for workflow_name, workflow_text in (
    ('CI', ci),
    ('release', release),
    ('bootstrap', bootstrap),
):
    if actionlint_install not in workflow_text or 'run: actionlint' not in workflow_text:
        raise SystemExit(f'{workflow_name} workflow must install pinned actionlint and run it')
if ".github/workflows/codeql.yml" not in codeql:
    raise SystemExit('CodeQL workflow changes must trigger CodeQL validation')
if 'schedule:' in codeql or 'schedule:' in scheduled_live:
    raise SystemExit('CodeQL and live-network workflows must remain manual-only to control Actions usage')

policy = yaml.safe_load(Path('.github/dependabot.yml').read_text(encoding='utf-8'))
if not isinstance(policy, dict):
    raise SystemExit('dependabot configuration is invalid')
ecosystems = {item.get('package-ecosystem') for item in policy.get('updates', []) if isinstance(item, dict)}
if not {'github-actions', 'gomod', 'docker'} <= ecosystems:
    raise SystemExit('Dependabot must cover GitHub Actions, Go modules, and Docker')
print('workflow and repository policy checks passed')
PY

# Bridge live validation must preserve the secret boundary and cleanup lifecycle.
grep -Fq "Bridge input must be stored outside the Git repository" scripts/bridge-live-test.sh
grep -Fq "The secret travels only over stdin" scripts/bridge-live-test.sh
grep -Fq "docker volume rm -f" scripts/bridge-live-test.sh
grep -Fq "logs suppressed to protect Bridge data" scripts/bridge-live-test.sh
grep -Fq "target=/run/bridge-input,readonly" scripts/bridge-live-test.sh

echo 'repository validation passed'
