# Test strategy

Pull requests run Go race tests, `go vet`, formatting, repository/privacy policy,
release-tool and runtime-budget regression tests, Docker amd64 native
configuration tests, deterministic Compose network tests, and an image/package
inventory upload. The local Docker suite additionally includes an explicit
real-container child-failure supervision test.

For a developer-machine checklist that closes the remaining full-validation
gap, see [the Japanese local full validation runbook](LOCAL_FULL_VALIDATION_JA.md).

Scheduled tests build the image, verify SOCKS5 and HTTP paths through the live
Tor network, and retain bootstrap, memory, PID, idle-CPU, image-size, and package
inventory evidence.

Tagged releases additionally require amd64 live tests, arm64 QEMU config tests,
exact OCI runtime/attestation shape, HIGH/CRITICAL vulnerability policy,
runtime budgets, source archives, registry-local digest evidence, anonymous
registry access, and final tag identity checks.

## Repository-owned proxy validation client

The static `proxycheck` image performs HTTPS through SOCKS5 with domain-name framing or through HTTP CONNECT. The local live-smoke path validates the Tor-check boolean without a host Python dependency and never prints the response body. The Windows validation bundle runs it from the internal client network, so a successful request proves the client reached the Internet through ToRoute rather than through a direct container route.

## Real-container child failure

`scripts/docker-child-failure-test.sh` starts the hardened image with Tor and Privoxy, terminates each child in a separate case, and requires the supervisor to stop the peer process, emit a child-specific diagnostic, and return a non-zero container exit status. The test uses an isolated network and does not require live Tor bootstrap.

## User-executed Windows Docker evidence

The one-command Windows runner validates prerequisites, builds local amd64 and arm64 images, checks hardening and fail-closed configuration, verifies Compose gateway selection and direct-egress prevention, exercises SOCKS/HTTP/NEWNYM, records runtime metrics, scans logs, and packages all evidence even after failure.

## Tor cold-start readiness

Docker health uses a 420-second start period with 5-second start probes. The Windows evidence runner independently polls `toroute healthcheck --json` for up to 420 seconds and records every observation in `bootstrap-progress.jsonl`. A running process at partial bootstrap is not treated as ready, but transient directory-download delay must not become `unhealthy` before the configured live-test deadline.


## Bridge live validation

The Bridge live harness rejects repository-local and symlink inputs, stages the secret through stdin into an ephemeral Docker volume as UID/GID 65532 with mode 0600, starts the normal hardened runtime with the volume read-only, requires Tor health and a SOCKS5 Tor-path check, compares every non-comment source line against captured logs without printing either, and removes the test container and secret volume on every exit. A real Bridge line is maintainer-only input and is never committed or attached as evidence.

The source gate runs no-secret preflight regressions for repository-local, symlink, empty, and oversized Bridge inputs. Every case must fail before any Docker command is reached.
