# Migration from dperson/torproxy

ToRoute keeps the useful client-proxy interface while refusing legacy features
that silently turn a client proxy into a server, relay, or network-control
endpoint.

## Compatibility and replacement matrix

| Legacy behavior / setting | ToRoute replacement | Notes |
|---|---|---|
| SOCKS `9050` | SOCKS `9050` | Same default container port. Existing applications can keep `socks5h://SERVICE:9050`. |
| HTTP `8118` | `TOROUTE_HTTP_ENABLED=true` | Available but default disabled to reduce processes and attack surface. |
| `-l JP` / `LOCATION=JP` | `TOROUTE_EXIT_COUNTRIES=jp` and `TOROUTE_STRICT_EXIT=true` | Limited legacy mode can translate `LOCATION`, but the typed API is preferred. |
| `TOR_ExitNodes={jp}` | `TOROUTE_EXIT_COUNTRIES=jp` | ToRoute accepts validated ISO country codes, not arbitrary relay fingerprints through the environment API. |
| `TOR_StrictNodes=1` | `TOROUTE_STRICT_EXIT=true` | Boolean must be exactly `true` or `false`. |
| `TOR_ExcludeNodes={cn},{ru}` | `TOROUTE_EXCLUDE_EXIT_COUNTRIES=cn,ru` | ToRoute excludes exit selection only. It does not expose a general path-wide `ExcludeNodes` environment variable because that can sharply reduce path diversity and availability. |
| `TOR_MaxCircuitDirtiness=600` | append file: `MaxCircuitDirtiness 600` | The append file is a small positive allowlist with value validation. |
| `TOR_NewCircuitPeriod=120` | append file: `NewCircuitPeriod 120` | Same allowlisted client-tuning mechanism. |
| `-n` | `toroute newnym` | Requests clean circuits for future streams; does not guarantee a new exit IP. |
| custom torrc | `TOROUTE_TORRC_APPEND_FILE` | Only reviewed client-tuning directives are accepted. Includes, listeners, identities, authorities, upstream credentials, and server roles are rejected. |
| ControlPort password / `PASSWORD` | private Unix socket + SAFECOOKIE | No TCP ControlPort and no reusable control password. |
| `USERID`, `GROUPID`, `USER_UID`, `USER_GID` | fixed `65532:65532` | Bind-mount ownership must be prepared by the operator; named volumes are preferred. Runtime UID mutation was removed so the container never needs startup root. |
| arbitrary `TOR_*` | rejected | Prevents typo-based silent failure and torrc text injection. |
| `-b` / relay bandwidth | rejected | Relay operation is a separate product and threat model. |
| `-e` / exit relay | rejected | ToRoute is client-only. |
| `-s` / Onion Service | outside v1.0 | Should be a separately scoped image or project if added later. |
| `9040`, `5353/udp` | not exposed | Transparent proxying, host firewall mutation, and external DNS proxying are outside v1.0. |

## Minimal service replacement

The Compose service itself may remain named `torproxy` so application URLs do
not have to change immediately:

```yaml
services:
  torproxy:
    image: ghcr.io/kabumatome/toroute:1.0.0
    read_only: true
    cap_drop: ["ALL"]
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /run/toroute:uid=65532,gid=65532,mode=0700
    volumes:
      - toroute-data:/var/lib/toroute

volumes:
  toroute-data: {}
```

Applications on the same Compose network can continue using:

```text
socks5h://torproxy:9050
```

Do not publish port 9050 to an untrusted host interface. The SOCKS listener has
no user authentication; the Docker network is the access boundary.

## Limited compatibility command

```text
toroute compat dperson -l JP
toroute compat dperson -n
```

The compatibility command accepts only safe migration operations. It does not
emulate relay, exit, Onion Service, generic torrc injection, or trailing-command
behavior.

## What “super-powered” means in ToRoute

The replacement adds capabilities that are operational rather than unsafe role
expansion:

- typed and fail-closed settings;
- native Tor and Privoxy validation before startup;
- bootstrap-aware health and JSON status;
- private SAFECOOKIE control operations;
- Bridge-file validation and redaction;
- process-group supervision and bounded shutdown;
- non-root/read-only/capability-free operation;
- direct-egress-reducing Compose topology;
- amd64/arm64 candidate identity checks;
- vulnerability, SBOM, provenance, registry, and runtime-budget evidence;
- reproducible source ZIP/tar packaging.
