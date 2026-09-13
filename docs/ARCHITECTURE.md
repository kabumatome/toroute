# Architecture

ToRoute is deliberately client-only. The Go supervisor renders runtime files,
runs native validators, starts Tor and optional Privoxy in separate process
groups, and exposes control operations only through a Unix socket protected by
SAFECOOKIE.

Persistent state lives in `/var/lib/toroute`. Ephemeral sockets, cookie, PID,
and generated configuration live in `/run/toroute`. Both are writable by UID
65532; the rest of the filesystem may be read-only.

The recommended Compose topology uses an internal client network and a separate
egress network with explicit gateway priority. It reduces accidental direct TCP
connections but does not replace application proxy/DNS configuration.

Releases build one multi-platform candidate to all configured registries in one
BuildKit invocation. Each registry's reported digest is inspected independently.
Tests address the GHCR candidate by digest. Final exact tags are created from the
registry-local candidate, verified, and only then are mutable stable aliases
updated.


## Runtime base and performance evidence

The v1.0 runtime is Debian 13 slim. The decision is based on complete signed
package availability and reduced native dependency branching, not an assumption
that Debian consumes less CPU. The release candidate records image/package
inventory and live cgroup metrics. Stable releases require active reviewed
budgets. Alpine is evaluated only as a feature-complete post-v1.0 variant; see
`BASE_IMAGE_DECISION.md`.
