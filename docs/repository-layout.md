# Repository layout

The repository separates reproducible source from machine-local bring-up state.

## Tracked content

- public documentation
- local pmaports package snapshots
- small C helpers and experimental patches
- build and test scripts
- host integration examples
- configuration templates without credentials

## Local-only content

- external Git checkouts
- compiled binaries and packages
- boot images and root filesystems
- phone partition dumps
- runtime logs and PID files
- machine-specific pmbootstrap configuration
- downloaded proprietary firmware

The local-only paths are listed in `.gitignore`.

## Documentation policy

Current instructions use repository-relative paths and configurable
environment variables. Raw experiment reports remain in the ignored local
`reports/` directory; only sanitized, durable conclusions are promoted into
tracked documentation.

Public-facing status belongs in `README.md` and `docs/`. New experiments should
update those documents only after a result is reproduced or clearly labeled as
unvalidated.

## Artifact policy

Do not commit generated boot images, proprietary partition dumps, firmware
blobs, or full logs. Publish a build recipe, source commit, file size, SHA256,
and concise evidence instead.
