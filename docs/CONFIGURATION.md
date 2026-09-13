# Configuration

| Variable | Default | Meaning |
|---|---|---|
| `TOROUTE_SOCKS_ADDRESS` | `0.0.0.0:9050` | SOCKS listener |
| `TOROUTE_HTTP_ENABLED` | `false` | enable Privoxy adapter |
| `TOROUTE_HTTP_ADDRESS` | `0.0.0.0:8118` | HTTP listener |
| `TOROUTE_DATA_DIR` | `/var/lib/toroute` | persistent state |
| `TOROUTE_RUNTIME_DIR` | `/run/toroute` | ephemeral runtime |
| `TOROUTE_EXIT_COUNTRIES` | empty | preferred ISO alpha-2 countries |
| `TOROUTE_STRICT_EXIT` | `false` | require preferred exits |
| `TOROUTE_EXCLUDE_EXIT_COUNTRIES` | empty | excluded exit countries |
| `TOROUTE_BRIDGES_FILE` | empty | validated obfs4 bridge file |
| `TOROUTE_TORRC_APPEND_FILE` | empty | reviewed client-tuning allowlist |
| `TOROUTE_LOG_LEVEL` | `notice` | Tor stdout level |
| `TOROUTE_SHUTDOWN_TIMEOUT` | `15s` | graceful stop deadline |
| `TOROUTE_CONTROL_TIMEOUT` | `5s` | control operation deadline |
| `TOROUTE_CONFIG_VERIFY_TIMEOUT` | `20s` | native validator deadline |
| `TOROUTE_ENABLE_LEGACY_ENV` | `false` | limited `LOCATION` migration |

Boolean values must be exactly `true` or `false`. Unknown `TOROUTE_*`, generic
`TOR_*`, and legacy server-role variables are rejected. Optional file/list
settings may be empty; safety-critical scalar settings may not.

Allowed append directives are currently `AvoidDiskWrites`,
`CircuitBuildTimeout`, `ConnectionPadding`, `FascistFirewall`,
`LearnCircuitBuildTimeout`, `MaxCircuitDirtiness`, `NewCircuitPeriod`, and
`TestSocks`, with value validation and duplicate rejection.

Bridge files are secrets. On Linux they must be regular non-symlink files owned
by the ToRoute process UID and must not grant any group or other permissions
(for example, mode `0600` or `0400`). ToRoute rejects a bridge file that does
not meet these requirements before rendering its contents.


## Secure Bridge staging

A normal Compose file-secret is generally mounted as root-owned and read-only, so it does not satisfy ToRoute's owner/private-mode boundary directly. Do not weaken the boundary or pass a Bridge line in an environment variable, command argument, issue, or log.

Use `scripts/bridge-live-test.sh IMAGE ABSOLUTE_BRIDGE_FILE` for validation. It rejects files inside the Git repository, streams the secret over stdin into an ephemeral Docker volume, sets owner `65532:65532` and mode `0600`, mounts it read-only into ToRoute, checks logs for exact source-line leakage without displaying them, and removes both container and volume on exit.

The Compose example uses the same staging pattern. Set `TOROUTE_BRIDGES_SOURCE` to an absolute path outside the repository and always tear it down with `docker compose -f examples/compose-bridges.yml down -v` so the secret volume is deleted.
