# Naming status

`ToRoute` is the current working and release-candidate name and is used
consistently in source, documentation, environment variables, images, and CLI.

Naming clearance is intentionally deferred by the project owner. It is not a
technical Source RC or Container RC blocker. If repository, registry, domain,
or trademark review later requires a different name, the project must perform
a repository-wide migration of:

- Go module and imports;
- CLI binary and environment prefix;
- image/repository names and OCI labels;
- filesystem paths, Compose examples, docs, tags, and release evidence.

A rename must pass the full source, Docker, live-network, and release-policy
suite. No statement in this file is legal or trademark advice.
