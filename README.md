# ToRoute

> **Status: 0.4.0-rc.12 source candidate. rc.8 passed all 12 Container RC checks and rc.9 hardened Docker health synchronization. rc.10 makes Windows double-click launches use a persistent console and records diagnostics before PowerShell starts. rc.11 hardens Bridge secret-file ownership and permissions and adds explicit release/cost controls. rc.12 fails closed on unidentified source archives and introduces public-safe evidence summaries. Not yet a public v1.0 release.**

ToRoute is an independent, security-focused containerized Tor client for
applications that need outbound TCP connectivity through a SOCKS5 proxy. It is
not developed, endorsed, or supported by The Tor Project.

## What it provides

- SOCKS5 on `9050/tcp`
- optional HTTP-to-SOCKS adapter on `8118/tcp`
- typed, fail-closed configuration
- Unix control socket and SAFECOOKIE authentication
- bootstrap-aware health checks and JSON status
- exit-country preferences and exclusions
- validated obfs4 bridge files
- non-root, read-only-root-filesystem operation
- amd64 and arm64 release design

It does **not** provide relay/exit operation, onion-service hosting,
transparent routing, UDP tunneling, browser fingerprint protection, or a
complete anonymity guarantee.

## Recommended Compose topology

The application joins only an internal network. ToRoute also joins a separate
egress network. `gw_priority` makes the egress network ToRoute's default route.

```yaml
services:
  toroute:
    image: ghcr.io/kabumatome/toroute:1.0.0
    read_only: true
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /run/toroute:uid=65532,gid=65532,mode=0700
    volumes:
      - toroute-data:/var/lib/toroute
    networks:
      client: {}
      egress:
        gw_priority: 1

  app:
    image: your-application-image
    environment:
      ALL_PROXY: socks5h://toroute:9050
    networks: [client]

networks:
  client:
    internal: true
  egress: {}
volumes:
  toroute-data: {}
```

Use `socks5h` when the client supports it so hostname resolution occurs through
the proxy. An internal Docker network reduces accidental direct TCP egress but
is not a complete DNS-leak or sandbox boundary.


After direct Tor readiness reaches 100%, the Windows evidence runner waits up to 45 seconds for Docker health to become `healthy`. Every `starting`/`healthy` observation is retained in `docker-health-sync.jsonl`; `unhealthy`, a stopped container, missing health state, or timeout fails closed.

## One-command Docker validation on Windows

With Docker Desktop running, execute the following from the extracted source root. The command builds the images, runs the hardened container and network checks, verifies live SOCKS5 and HTTP Tor paths, collects runtime evidence, checks arm64 under QEMU, and produces a result ZIP. It does not require WSL, Git Bash, Go, Python, or host curl.

```cmd
.\RUN_DOCKER_VALIDATION.cmd
```

0.4.0-rc.10 relaunches Explorer double-clicks into a persistent `cmd.exe /k` console. It records pre-PowerShell startup diagnostics in `validation-results\launcher-bootstrap.log` and parser/runtime diagnostics in `validation-results\last-launch.log`.
0.4.0-rc.5 fixed `check-config` under a read-only root filesystem. 0.4.0-rc.6 activated runtime/package budgets and reduced the runtime dependency set. 0.4.0-rc.8 completed all 12 Container RC checks and replaced shell-based cgroup evidence collection with direct file reads. rc.9 only synchronizes Docker health-state propagation after direct Tor readiness.

See [the Japanese Windows validation guide](docs/DOCKER_VALIDATION_WINDOWS_JA.md).

## Runtime base and lightweight roadmap

The v1.0 default runtime is `debian:trixie-slim`. This is not a CPU-speed
claim. It keeps Tor, Privoxy, obfs4proxy, GeoIP data, and Tini in one signed
distribution package set and avoids adding a second native-libc/package branch
before the first stable release. Runtime cost is dominated by Tor cryptography,
circuit construction, directory processing, and traffic; the base choice
mostly affects pull/extracted size, package provenance, and compatibility.

Alpine remains a formal post-v1.0 experiment. It must retain full feature
parity and pass the same amd64/arm64, Bridge, live Tor, vulnerability,
SBOM/provenance, and release-identity gates. Release candidates record image
size, bootstrap time, steady memory, PID count, and idle CPU as JSON evidence.
See [the base-image decision](docs/BASE_IMAGE_DECISION.md).

## CLI

```text
toroute run
toroute check-config
toroute print-config [--format torrc|privoxy|json]
toroute status [--json]
toroute healthcheck [--json]
toroute newnym
toroute exec [--] <command> [args...]
toroute compat dperson [-l CC] [-n]
toroute version
```

`status` is informational. `healthcheck` fails until bootstrap reaches 100 and
a TCP SOCKS listener exists. `newnym` affects future streams and does not
guarantee a different exit IP.
Tor cold starts can be delayed while directory data is downloaded. The image health check allows a 420-second startup grace period, probes every 5 seconds during that period, and switches to the normal 30-second interval after the first success. Bootstrap below 100% is never reported as ready.


## Security defaults

- fixed UID/GID `65532:65532`
- no Linux capabilities
- `no-new-privileges`
- no TCP ControlPort
- SAFECOOKIE over a private Unix socket
- `SafeSocks 1`, `SafeLogging 1`, stream isolation flags
- destination logging disabled in the HTTP adapter
- unknown or unsafe legacy variables rejected
- bridge lines redacted from diagnostic output

## Current validation status

Source tests, race detector, `go vet`, repository policy checks, privacy scans,
release-tool tests, OCI policy tests, active runtime/package budgets, and
vulnerability-policy tests are provided as bounded source gates. External Docker
evidence for 0.4.0-rc.5 passed amd64 build/config/live paths, network isolation,
SOCKS5 remote DNS, HTTP CONNECT, SAFECOOKIE/NEWNYM, runtime metrics, log scanning,
and arm64 QEMU configuration. Actual registry, Trivy, SBOM/provenance, and public
pull gates remain pending.

See [the Container RC evidence](docs/CONTAINER_RC_EVIDENCE_JA.md) and
[the Japanese requirements/design/progress report](docs/REQUIREMENTS_AND_DESIGN_JA.md).

For the remaining developer-machine full validation gate, see
[the local full validation runbook](docs/LOCAL_FULL_VALIDATION_JA.md).
