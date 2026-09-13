# Base image decision and lightweight roadmap

Status: accepted for the v1.0 release line  
Decision date: 2026-07-20  
Default runtime: `debian:trixie-slim`

## Decision

ToRoute v1.0 keeps Debian 13 (`trixie-slim`) as its default runtime base.
This is a reliability and package-supply decision, not a claim that Debian
executes Tor faster than Alpine.

The operating-system base mainly affects image download size, extracted disk
usage, package provenance, libc compatibility, and maintenance work. Once the
container is running, Tor's cryptography, circuit construction, directory
processing, and network traffic dominate CPU and memory. The default profile
starts Tor only. Privoxy starts only when the HTTP adapter is enabled, and
obfs4proxy is spawned by Tor only when Bridge configuration requires it. Thus
optional features do not add permanent process cost when unused.

## Why Debian is the v1.0 default

1. **Complete feature set from one signed distribution.** Debian stable ships
   Tor, Privoxy, `obfs4proxy`, Tini, and the Tor GeoIP database
   as distribution packages. ToRoute does not need to download or compile a
   separate pluggable-transport binary during the production build.
2. **Feature parity with the product goal.** obfs4 Bridge support is part of the
   v1.0 scope. Dropping it merely to reduce the image would make the smaller
   image a different product.
3. **Lower supply-chain complexity.** Building obfs4proxy from an additional
   source repository would add another compiler stage, module graph, version
   pin, checksum/update process, SBOM review, and vulnerability boundary.
4. **glibc compatibility and predictable native packages.** The Go supervisor
   is static, but Tor and Privoxy are native dynamically linked programs.
   Debian avoids introducing a musl-specific compatibility branch before the
   first stable release.
5. **Conservative migration from dperson/torproxy.** The replacement should
   improve operational safety without simultaneously changing every native
   packaging assumption.

The current Dockerfile already uses `trixie-slim`, `--no-install-recommends`, a
static Go binary, a non-root runtime user, and removes APT index files. The
runtime image does not contain a Go toolchain. `adduser` is listed explicitly
so user/group creation does not rely on an incidental transitive dependency.

The human-readable base tags are intentionally updated by Dependabot and release
builds use `pull: true`; ToRoute does not claim bit-for-bit reproducible runtime
images from mutable distribution repositories. Instead, each release creates one
candidate, records the exact resolved base materials in maximum-mode provenance,
then tests and promotes that candidate without rebuilding. Exact published tags
and their platform manifests remain immutable.

## v1.0 lightweight adjustment

The full runtime does not act as a general HTTPS client: Tor authenticates its own
network protocol and Privoxy tunnels HTTP CONNECT without terminating TLS. The
0.4.0-rc.6 Dockerfile therefore stops explicitly installing `ca-certificates`
and the OpenSSL command-line package it pulled in. The scratch `proxycheck` test
image still carries a CA bundle because it performs HTTPS verification. This is
a small, low-complexity reduction; package-manager-bypassing extraction of Tor,
Privoxy, or obfs4proxy is explicitly deferred.

## Alpine assessment

Alpine is a legitimate post-v1.0 optimization candidate. Its base images are
smaller and use musl libc. Alpine stable currently provides Tor, Privoxy, and
Tini packages. However, the stable package search performed for this decision
did not provide an equivalent packaged `obfs4proxy`, while full ToRoute feature
parity requires it. An Alpine image would therefore need one of the following:

- compile and pin obfs4proxy separately;
- replace it with another transport and change the public feature contract; or
- publish a reduced feature variant.

None of those changes is a free base-image swap. They increase testing and
maintenance work or fragment the product. Docker's own guidance also notes that
Alpine's smaller size comes with the musl-versus-glibc compatibility tradeoff.

## Runtime and image metrics

ToRoute records the following for Docker candidates:

- Docker image size in bytes;
- distribution identity and installed package inventory;
- Tor bootstrap duration;
- stable memory samples from the container cgroup;
- PID count;
- idle CPU usage over a fixed sample interval.

A reviewed full-http amd64 Docker run on 2026-07-21 recorded a 142,596,144-byte image, 103 installed packages, 17.44-second bootstrap, 153,251,840-byte maximum cgroup memory, 13,082 usec/s idle CPU, and 29 PIDs/threads. `security/runtime-budgets.json` is now active with explicit regression headroom, and `security/runtime-baseline-full-http-amd64.json` retains the sanitized baseline. Stable releases are blocked when any candidate exceeds a limit.

## Post-v1.0 Alpine experiment gate

An Alpine variant or base switch is accepted only when all conditions below are
met on both amd64 and arm64:

1. SOCKS, optional HTTP, obfs4 Bridge, country selection, SAFECOOKIE,
   healthcheck, read-only root filesystem, and process supervision have full
   parity.
2. The exact same native configuration, live Tor, network isolation,
   vulnerability, SBOM, provenance, and release-identity gates pass.
3. No mutable download or unverified source-build step is introduced.
4. The measured compressed/pulled image or local image size improves by at
   least 25%, **or** startup/bootstrap distribution improves by at least 15%.
5. Idle memory and CPU do not regress by more than 5%.
6. HIGH/CRITICAL vulnerability policy is no worse than the Debian image.
7. The maintenance procedure for obfs4 and security updates is documented and
   exercised.

These percentages are project acceptance thresholds, not claims about Debian
or Alpine in general.

## Other lightweight options

After v1.0, measurements may justify separate variants:

- `full`: current feature-complete image;
- `socks`: Tor SOCKS only, without Privoxy or pluggable transports;
- an Alpine full-parity experiment.

Variants will not be introduced before v1.0 because users primarily need one
predictable replacement image. Premature variants multiply documentation,
security scans, tags, test matrices, and support cases.
