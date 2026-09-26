# ToRoute documentation

This directory separates **current product guidance** from **validation/release operations** and **historical evidence**. When changing behavior, update the current documents first; historical records should normally remain immutable.

## Current design and configuration

- [Requirements, design, and progress (Japanese)](core/REQUIREMENTS_AND_DESIGN_JA.md) — product scope, security boundaries, current gates, and remaining work.
- [Architecture](core/ARCHITECTURE.md) — runtime layout, control boundary, network topology, and release artifact flow.
- [Configuration](core/CONFIGURATION.md) — supported `TOROUTE_*` settings and Bridge handling.
- [Threat model](core/THREAT_MODEL.md) — protected assets, trust boundaries, mitigations, and out-of-scope threats.
- [Migration from dperson/torproxy](core/MIGRATION_DPERSON.md) — compatibility mapping and safe migration guidance.
- [Naming](core/NAMING.md) — current naming status and rename requirements.

## Validation

- [Test strategy](validation/TEST_STRATEGY.md) — source, container, network, Bridge, and release validation strategy.
- [Windows Docker validation (Japanese)](validation/DOCKER_VALIDATION_WINDOWS_JA.md) — one-command Docker Desktop evidence run.
- [Local full validation (Japanese)](validation/LOCAL_FULL_VALIDATION_JA.md) — developer-machine checklist for remaining full gates.

## Release and maintenance

- [Release criteria](release/RELEASE_CRITERIA.md) — blocking conditions and public-release gate.
- [Maintainer release guide (Japanese)](release/MAINTAINER_RELEASE_GUIDE_JA.md) — maintainer release procedure.
- [Base image decision](release/BASE_IMAGE_DECISION.md) — Debian 13 decision, budgets, and post-v1.0 Alpine experiment criteria.

## Historical records

Files under [history/](history/) document past RCs, recovery events, validation snapshots, and sign-offs. They are useful for provenance and regression archaeology, but they are **not** the primary source of current requirements.

Key records:

- [Container RC evidence (Japanese)](history/CONTAINER_RC_EVIDENCE_JA.md)
- [Validation report (Japanese)](history/VALIDATION_REPORT_JA.md)
- [rc.8 Container RC sign-off](history/RC8_CONTAINER_RC_SIGNOFF_JA.md)
- [rc.10 Windows launcher hotfix](history/RC10_LAUNCHER_HOTFIX_JA.md)
- [Recovery provenance](history/RECOVERY_PROVENANCE_JA.md)

## Evidence and references

- [evidence/](evidence/) contains sanitized, machine-readable public summaries only. Raw validation archives must remain outside the public repository.
- [Primary references](references/SOURCES.md) lists upstream specifications and operational references.

## Documentation maintenance rules

1. Prefer updating an existing current document over creating another progress memo.
2. Put point-in-time RC reports, incident/recovery notes, and superseded sign-offs in `history/`.
3. Keep raw machine evidence out of Git; only privacy-reviewed summaries belong in `evidence/`.
4. Keep root `README.md` and `README.ja.md` concise and route deeper topics through this index.
5. When moving a document, update repository links in the same commit.
