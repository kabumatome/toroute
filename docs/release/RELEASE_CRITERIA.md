# Release criteria

A release is blocked by any failed or skipped mandatory test, dirty source tree,
remaining `OWNER` placeholder, exact tag collision,
HIGH/CRITICAL finding without an exact tracked exception, missing attestation,
unexpected runtime platform, candidate/final identity mismatch, private GHCR
package, secret/privacy finding, unresolved high-severity security issue, or a
stable release attempted before runtime budgets are baselined.

Exact version tags are immutable. Failed partial releases are investigated and
verified; exact tags are never overwritten. A new version is used when artifact
identity cannot be proven.

## Public release gate

The repository remains private until a maintainer explicitly completes the
public release gate. Before changing repository visibility or publishing a
stable release, confirm all of the following:

- GitHub private vulnerability reporting is enabled.
- Release immutability is enabled.
- GitHub Actions is enabled only under the reviewed Actions policy: selected
  actions, full-length SHA pinning, read-only default workflow token, and no fork
  pull request secrets.
- Registry publication is disabled by default. The maintainer sets
  `TOROUTE_RELEASES_ENABLED=true` only for a deliberate release, and the tag
  must point to the current `main` commit.
- Raw checkpoints, internal logs, local machine paths, bridge lines, credentials,
  private hostnames, and proprietary traffic samples are not present in the
  repository, release assets, packages, or issue/PR history.
- Internal-only classification labels and instructions to share raw validation ZIPs
  have been removed; raw evidence remains outside the public repository.
- All owner, image, support, and security-reporting links point to
  `kabumatome/toroute` or to the deliberately selected release owner.
- The full validation suite has passed in a Go, Docker, and Windows-capable
  environment.

## Runtime and footprint gate

Every Docker candidate records an image/package inventory. Every live amd64
candidate records Tor bootstrap time, steady cgroup memory, PID count, and idle
CPU. `security/runtime-budgets.json` is active from reviewed full-http amd64 evidence and covers image size, installed package count, bootstrap time, cgroup memory, PID/thread count, and idle CPU. Every release candidate must record the same metrics. Exceeding any limit blocks release.

The v1.0 default base remains Debian 13 slim. An Alpine switch or variant is a
post-v1.0 change and must meet the parity and benchmark criteria in
`BASE_IMAGE_DECISION.md`.
