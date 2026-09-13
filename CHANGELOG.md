# Changelog

## 0.4.0-rc.12 — evidence provenance and public-summary hardening

- Fail Windows validation when neither a Git commit nor valid packaged `SOURCE_METADATA.json` can identify the source.
- Add a bounded allowlist-based sanitizer that converts private validation evidence into a public-safe JSON summary.
- Cross-check source identity against the tested OCI image version/revision labels and add malformed-input and leakage regression tests.
- Record the successful rc.10 Windows/Docker 12-check rerun as functional evidence while explicitly rejecting it for release identity.
- Keep raw Docker/PowerShell evidence private and publish only the generated minimal summary.
- Remove the duplicate hard-coded version from the outer Windows launcher and enforce the single-source version contract.
- Pass the verified-commit rc.12 Windows/Docker full validation: all 12 checks and all active runtime budgets.
- Preserve the container toolchain PATH by prohibiting login shells in source validation.
- Make ShellCheck a required source-validation gate and resolve all existing shell diagnostics without changing runtime behavior.
- Add an offline real-container Tor/Privoxy child-failure supervision test and record both failure paths passing on Docker Desktop.
- Make live proxy diagnostics Windows/Git-Bash-safe, platform-explicit, free of host-Python dependency, and free of response-body or exit-IP output.
- Pass arm64 QEMU live Tor bootstrap, SOCKS5, HTTP CONNECT, HTTPS, and Tor-route validation.
- Replace the non-functional direct Compose Bridge secret example with owner/mode-preserving staging and add a privacy-safe live harness.
- Add no-secret source-gate regressions for repository-local, symlink, empty, and oversized Bridge inputs.
- Preserve least privilege in Bridge staging by setting mode before transferring ownership with only `CAP_CHOWN`.

## 0.4.0-rc.11 — security-boundary and release-control audit

- Enforce current-UID ownership and private permissions on obfs4 Bridge files before reading them.
- Add regression coverage for group/world-readable Bridge secret rejection.
- Remove stale source-archive metadata from the Git checkout and prohibit tracking it again.
- Make live-network and CodeQL schedules manual while the repository remains private.
- Skip heavyweight CI for documentation-only changes and retain an explicit manual CI entry point.
- Require an explicit repository release-enable variable and the release commit to equal current `main` before registry publication.
- Reconcile completion criteria and remaining external validation gates after the design audit.

## 0.4.0-rc.10 — persistent Windows console launcher

- Relaunch Explorer double-clicks into a persistent child `cmd.exe /k` console that remains open after the validation command returns.
- Redirect direct execution of the inner Windows launcher back through the persistent root launcher.
- Create `validation-results/launcher-bootstrap.log` before PowerShell parsing or Docker access.
- Remove user-controlled no-pause environment variables entirely; only the GitHub Actions platform marker enables noninteractive execution.
- Add static regression checks for the persistent-console, direct-inner-launch, and bootstrap-log contracts.

## 0.4.0-rc.9 — Docker health synchronization after direct Tor readiness

- Preserve the reviewed rc.8 Container RC evidence and update the sanitized runtime baseline to the successful 2026-07-22 full-http amd64 measurements.
- After direct `toroute healthcheck --json` reports ready at 100%, wait up to 45 seconds for Docker's asynchronous health state to change from `starting` to `healthy`.
- Record each Docker health synchronization observation in `docker-health-sync.jsonl`.
- Treat `starting` as a temporary synchronization state, `healthy` as success, and `unhealthy`, a stopped container, missing health, invalid JSON, or timeout as fail-closed errors.
- Add Windows PowerShell 5.1 self-tests and static/repository contracts for every health-state transition and for synchronization ordering before hardened-state assertions.
- Record recovery provenance from the byte-identical rc.8 source archive rather than claiming the unavailable original Git history.

## 0.4.0-rc.8 — resilient Tor cold-start readiness and quote-free evidence collection

- Require Docker Engine 25.0+ because startup probe intervals use the Engine health start-interval field.
- Extend Tor cold-start health grace to 420 seconds with 5-second startup probes.
- Poll bootstrap JSON directly in the Windows Docker evidence runner and retain progress as JSONL.
- Replace Windows-to-container multiline `/bin/sh -c` metric collection with direct `docker exec /bin/cat` reads and PowerShell-side cgroup v1/v2 parsing.
- Keep log auditing and arm64 validation running after a metrics-only evidence failure.
- Record the reduced exact-image footprint of 140,775,431 bytes and 101 packages.

## 0.4.0-rc.6 — reviewed Container RC evidence and active footprint budget

- Record the successful 0.4.0-rc.5 Windows Docker validation: all 12 checks passed, including amd64 live SOCKS/HTTP Tor paths, network isolation, SAFECOOKIE/NEWNYM, runtime metrics, log scanning, and arm64 QEMU configuration.
- Add a sanitized full-http amd64 baseline without user paths, host identity, exit IPs, or raw logs.
- Activate release budgets for image size, installed package count, bootstrap time, steady cgroup memory, idle CPU, and PID/thread count.
- Add package count to the runtime regression policy and require the reviewed baseline in repository validation.
- Stop explicitly installing `ca-certificates` in the runtime image; the HTTPS-only proxycheck test image retains its CA bundle.
- Update requirements, progress, validation, and base-image documents from Source-RC-only status to Container RC evidence.

## 0.4.0-rc.5 — read-only configuration check and native runner correction

- Make `toroute check-config` create its isolated workspace under the configured writable runtime directory instead of system `/tmp`, so the command works with a read-only root filesystem.
- Add a regression test that makes the system temporary directory unusable, preserves live runtime sentinels, and verifies removal of the isolated check workspace.
- Replace PowerShell native invocation through the shell adapter with `System.Diagnostics.ProcessStartInfo`, keeping stdout, stderr, UTF-8 decoding, and exit status separate without `NativeCommandError` noise on successful BuildKit output.
- Exercise the native runner with a child PowerShell path and argument containing spaces before Docker is used.
- Prefer the actual Git HEAD in checkouts and packaged `SOURCE_METADATA.json` only in clean source archives; remove generated metadata from the tracked source tree.
- Add repository policy that prohibits configuration checks from falling back to system `/tmp` and prohibits PowerShell `& $FilePath @Arguments` execution.
- Record the first external Docker evidence: all prerequisites and amd64 image builds passed; the runtime image was 142,596,144 bytes and failed only when the old check-config attempted to write `/tmp` under a read-only root.

## 0.4.0-rc.4 — source-archive runtime validation correction

- Stop treating a Git checkout as a prerequisite for the Windows Docker validation bundle.
- Add deterministic `SOURCE_METADATA.json` to packaged source archives and use it for OCI build identity.
- Probe Git only when an actual `.git` entry exists; clean source ZIPs use archive metadata instead.
- Replace Windows PowerShell 5.1 native `2>&1` capture with separate stdout/stderr files and explicit exit-code handling.
- Add a Windows PowerShell runtime self-test covering stdout, stderr, non-zero exit status, source identity, and JSON evidence serialization before Docker is invoked.
- Remove generic `List[T]` conversions from the Windows evidence path to avoid the Windows PowerShell 5.1 `Argument types do not match` binder failure.
- Add an archive-mode Windows CI test that removes `.git` and runs the full runtime preflight, not only the parser.
- Exclude local validation evidence from source packages.

## 0.4.0-rc.3 — Windows PowerShell 5.1 parser correction

- Correct variable interpolation before a colon by using `${exitCode}`.
- Replace the C-style escaped `awk` command with a single-quoted PowerShell string and a quote-safe POSIX shell route parser.
- Use a single-quoted `dpkg-query` format argument so PowerShell does not interpret package-format variables or escapes.
- Extend the Windows static contract to reject C-style `\"` escaping inside expandable strings and unbraced variables immediately followed by a colon.
- Record the user-reported parser regression as a permanent release test.
- Add a Windows CI job that executes the launcher parse-only path with Windows PowerShell 5.1 and separately parses the script with PowerShell 7.

## 0.4.0-rc.2 — visible and diagnosable Windows launcher

- Keep the command window open after success or failure when launched from Explorer.
- Write launcher diagnostics to `validation-results\last-launch.log` before the main PowerShell script starts.
- Parse the main PowerShell script with the built-in PowerShell parser before execution and print parser errors instead of closing silently.
- Start a PowerShell transcript at the beginning of validation and include it in the evidence ZIP.
- Print the selected PowerShell executable, repository path, exit code, result location, and next action.
- Add static regression checks that prohibit a silent `exit /b` root launcher.

## 0.4.0-rc.1 — one-command Windows Docker evidence

- Add the root-level `RUN_DOCKER_VALIDATION.cmd` launcher for a one-command Docker Desktop validation run.
- Build repository-owned scratch `netprobe` and `proxycheck` images; proxycheck verifies SOCKS5 remote DNS and HTTP CONNECT through real TLS without host curl, Python, WSL, or Git Bash.
- Collect success and failure evidence, including final Compose state, logs, container inspection, runtime cgroup metrics, image/package inventory, and a shareable result ZIP.
- Verify amd64 hardening and live paths plus arm64 configuration under Docker Desktop QEMU.
- Add static Windows PowerShell 5.1 encoding/syntax/dependency contracts and local proxy tunnel tests.
- Retry final registry tag inspection to tolerate normal manifest propagation delay without weakening identity comparison.

## 0.3.0-rc.1 — runtime evidence and base-image decision

- Kept Debian 13 slim as the v1.0 default based on complete signed package
  availability, obfs4 feature parity, and lower native supply-chain complexity.
- Added a documented post-v1.0 Alpine parity/benchmark decision gate rather than
  switching the base without Docker evidence.
- Added Docker image/package inventory evidence.
- Added live bootstrap, cgroup memory, PID, and idle CPU metrics.
- Added reviewed runtime-budget policy; stable releases are blocked while the
  budget is unbaselined or when a candidate exceeds an active limit.
- Added CI, scheduled-live, bootstrap, and release artifact retention for the
  new footprint and runtime evidence.
- Updated vulnerability scanning to the full-SHA-pinned Trivy Action v0.36.0
  and explicitly pinned the scanner binary to v0.72.0.
- Added bounded package-by-package race/coverage execution and in-process policy
  tests to reduce low-resource validation stalls.
- Split GitHub source compatibility and repository-policy gates into separate
  jobs/steps, and added the missing `python3-yaml` dependency to release jobs.
- Retained the complete Debian package inventory for release and bootstrap
  candidates, not only aggregate image metrics.
- Deferred naming and repository owner onboarding until after the technical v1.0
  candidate, without weakening Docker or release identity gates.

## 0.2.0-rc.1 — recovered source RC

- Reconstructed the project under the ToRoute working name.
- Added typed fail-closed configuration, client-only Tor rendering, optional
  neutral HTTP adapter, SAFECOOKIE control client, bounded validators, and PID 1
  process-group supervision.
- Added non-root/read-only Docker design, deterministic network isolation test,
  source/Docker/live/multi-arch workflows, registry-local digest promotion,
  vulnerability policy, SBOM/provenance generation, and complete public docs.
- Stabilized aggregate validation by removing redundant recompilation after owner replacement and using Bash-native SemVer validation.
- Required vulnerability reports for both amd64 and arm64.
- Added registry reflection retries and anonymous verification for exact, minor, major, and latest public tags.
- Added a current Japanese validation report with explicit unexecuted Docker and registry gates.
