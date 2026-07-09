# Repo continuation

This workspace is being prepared as a GitHub-friendly continuation point for the
OnePlus 7T Pro `hotdog` Linux bring-up.

## Goal

Keep the public repo focused on the material that helps someone resume work on
another machine:

- operational README and short status docs
- text patches and small helper scripts
- manifests that point to the important local artifacts
- bootstrap checks that never touch the phone

## What stays local

Do not try to vendor the heavy workspace tree into GitHub:

- `src/` holds external source checkouts, several with their own `.git`
- `build/`, `downloads/`, `images/`, `logs/`, `reports/`,
  `pmbootstrap-work/`, and `android-dumps/` are generated or capture data
- `rootfs/` is a local staging area
- `tools/` contains local binaries and caches that are better left out unless
  a specific small helper needs to be published

## Repo shape

The root repo can stay small and useful:

- `README.md`
- `.gitignore`
- `.gitattributes`
- `docs/*.md`
- `scripts/*.sh`
- `patches/*.patch`
- `pmbootstrap_v3.cfg.example`

The real `pmbootstrap_v3.cfg` is machine-local because it normally contains
absolute `aports` and `work` paths. Copy the example and adjust it on each host.

## Bootstrap flow

Run `./scripts/bootstrap-host.sh` on a fresh clone to print a read-only summary
and optionally chain into the existing host checks.

Recommended next step after cloning:

```bash
./scripts/bootstrap-host.sh
```

For a fuller host check without touching the phone:

```bash
./scripts/bootstrap-host.sh --check-host
./scripts/bootstrap-host.sh --autopilot
```

Fresh-machine checklist:

1. Clone the repo and enter it.
2. Run `./scripts/bootstrap-host.sh` to confirm the local layout.
3. Copy `pmbootstrap_v3.cfg.example` to `pmbootstrap_v3.cfg` and adjust paths if
   your pmbootstrap wrapper needs absolute paths.
4. Restore only the artifacts you need from `docs/artifact-manifest.md`, or
   regenerate them with the helper scripts already in the repo.
5. Re-run `./scripts/bootstrap-host.sh --check-host` before resuming work.

## GitHub notes

If the repo is published, keep the large runtime artifacts out of normal Git.
Use Git LFS only if a real need appears for small, curated binary artifacts in
the repo itself.
