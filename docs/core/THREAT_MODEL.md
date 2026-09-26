# Threat model

Protected assets include application routing, Tor client state, control cookie,
bridge lines, proxy availability, and release identity.

Trusted boundaries are the host kernel, Docker daemon, repository/registry
accounts, Debian/Tor/Privoxy upstreams, and containers deliberately attached to
the client network.

Mitigated threats include unauthenticated ControlPort takeover, configuration
injection, secret/log leakage, symlink/path attacks, partial child failure,
accidental direct TCP egress, and replacement of tested artifacts during
publication.

Out of scope are host compromise, Docker-admin attackers, global traffic
correlation, browser fingerprinting, application cookies/accounts/telemetry,
UDP/QUIC/WebRTC leaks, and denial of service by authorized clients.


Bridge staging treats the host source file and temporary Docker volume as secrets. Real Bridge lines must not enter Git, argv, environment values, issue/PR text, retained logs, or validation archives. The staging helper has no network, uses a read-only root filesystem, receives the source only over stdin, and retains only the narrowly required CHOWN capability. The runtime receives the staged file read-only and remains non-root with all capabilities dropped. Cleanup failure is security-relevant because a Docker volume can outlive its container.
