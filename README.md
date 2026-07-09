# OnePlus 7T Pro `hotdog` Linux bring-up

This repository tracks the Linux bring-up work for the OnePlus 7T Pro
(`hotdog`, HD1913) and its path toward postmarketOS and, longer term, a
maintainable downstream-to-mainline split.

## Project goal

- keep a reproducible pmOS bring-up path for `hotdog`
- collect the device facts needed to move changes into `pmaports`
- isolate the Linux mainline pieces that can eventually be upstreamed
- keep the workspace usable as a GitHub continuation point on another machine

## Current status

Status snapshot: 2026-07-10 00:22 CEST.

- a stable pmOS boot exists on the downstream Lineage/OpenELA 4.14.357 kernel
- the latest validated downstream image reaches USB SSH at `user@172.16.42.1`
  and starts a visible DRM text console from initramfs
- the live recovered boot id is `5a6cd93e-28c5-47dc-84fe-119534c8b2e1`
- `boot_b` is verified as the validated DRM-console image for the next normal
  boot
- host commands can be sent to the visible pmOS shell through
  `scripts/install-hotdog-drm-console.sh send`
- DSI-1 is visible: `modetest -s 28@136:#0 -F smpte` displays a test pattern
- the latest mainline 6.17 tests with DRM-console instrumentation still timed
  out before any USB recovery path; even the pstore-enabled kernel left no
  readable pstore record
- the older downstream image remains the current restore target for rescue
- future risky tests should start a fresh companion rescue watcher

The live boot state is tracked in [docs/current-boot-cycle.md](docs/current-boot-cycle.md).

## Risks and constraints

- this is bring-up work on real hardware, so some images can leave the device
  temporarily unreachable until fastboot or recovery ADB returns
- heavy runtime outputs stay out of Git
- phone-side actions are intentionally guarded by the local workflow and lock
  files

The repository is intended to stay lightweight and reviewable: mostly text,
scripts, manifests, and short reports.

## Repository layout

- `README.md`: project overview and quick resume path
- `docs/`: status notes, runbooks, and report pointers
- `scripts/`: host checks, boot helpers, and rescue workflows
- `patches/`: small text patches and experiments that are worth keeping
- `pmbootstrap_v3.cfg.example`: local pmbootstrap config template
- `src/`: external checkouts kept outside the normal Git history
- `reports/`: curated short reports may be tracked; large generated report
  bundles stay local
- `images/`, `logs/`, `build/`, `downloads/`,
  `pmbootstrap-work/`, `android-dumps/`, `rootfs/`, `tools/`: local-only
  workspace outputs

## Quick start

For a fresh clone or a resume on another machine:

```bash
./scripts/bootstrap-host.sh
```

That script prints a read-only summary of the workspace and never talks to the
phone. Useful follow-up checks:

```bash
./scripts/bootstrap-host.sh --check-host
./scripts/bootstrap-host.sh --autopilot
```

Typical resume flow:

1. clone the repository
2. run `./scripts/bootstrap-host.sh`
3. copy `pmbootstrap_v3.cfg.example` to `pmbootstrap_v3.cfg` if the local
   pmbootstrap wrapper needs a machine-specific config
4. review [docs/repo-continuation.md](docs/repo-continuation.md) and
   [docs/artifact-manifest.md](docs/artifact-manifest.md)
5. restore only the artifacts that are actually needed, or regenerate them with
   the scripts in this repo
6. re-run `./scripts/bootstrap-host.sh --check-host` before resuming device work

## Test workflow

The working pattern is:

1. validate the host with `./scripts/check-host-tools.sh`
2. confirm the pmbootstrap setup with `./scripts/pmbootstrap-hotdog.sh status`
3. build or refresh the relevant pmOS image, kernel, or device package
4. test on the phone only after a rescue path exists
5. for display-sensitive tests, prefer the validated DRM console path over the
   older `/dev/fb0` paint probe
6. capture the result in the matching log or report under `docs/` or `reports/`

The current boot-cycle notes document the stable downstream image, the latest
mainline failure mode, and the preferred rescue path:
[docs/current-boot-cycle.md](docs/current-boot-cycle.md)

## Excluded artifacts

These paths are kept local and are not meant to be committed as raw binaries:

- `images/`
- `logs/`
- `build/`
- `downloads/`
- bulk `reports/` output, except curated text reports added explicitly
- `pmbootstrap-work/`
- `android-dumps/`
- `rootfs/`
- `tools/`
- `src/`

The `.gitignore` file follows that split and keeps the Git history focused on
the project itself rather than on regenerated state.

## Documentation and reports

- [docs/repo-continuation.md](docs/repo-continuation.md)
- [docs/artifact-manifest.md](docs/artifact-manifest.md)
- [docs/source-status.md](docs/source-status.md)
- [docs/host-prep-status.md](docs/host-prep-status.md)
- [docs/hardware-status.md](docs/hardware-status.md)
- [docs/current-boot-cycle.md](docs/current-boot-cycle.md)
- [reports/lineage414-openela-diff-20260709-140656/99-report-index.txt](reports/lineage414-openela-diff-20260709-140656/99-report-index.txt)
- [reports/lineage414-openela-diff-20260709-140656/60-boot-test-findings-20260709.txt](reports/lineage414-openela-diff-20260709-140656/60-boot-test-findings-20260709.txt)
- [reports/lineage414-openela-diff-20260709-140656/66-devtmpfs-drm-plymouth-display-20260709.txt](reports/lineage414-openela-diff-20260709-140656/66-devtmpfs-drm-plymouth-display-20260709.txt)
- [reports/lineage414-openela-diff-20260709-140656/67-mainline617-timeout-20260709.txt](reports/lineage414-openela-diff-20260709-140656/67-mainline617-timeout-20260709.txt)
- [reports/lineage414-openela-diff-20260709-140656/68-mainline617-minramdisk-candidate-20260709.txt](reports/lineage414-openela-diff-20260709-140656/68-mainline617-minramdisk-candidate-20260709.txt)
- [reports/lineage414-openela-diff-20260709-140656/69-drm-visible-pattern-20260709.txt](reports/lineage414-openela-diff-20260709-140656/69-drm-visible-pattern-20260709.txt)
- [reports/lineage414-openela-diff-20260709-140656/70-drm-console-shell-initramfs-20260709.txt](reports/lineage414-openela-diff-20260709-140656/70-drm-console-shell-initramfs-20260709.txt)
- [reports/lineage414-openela-diff-20260709-140656/71-mainline617-drmconsole-timeout-20260709.txt](reports/lineage414-openela-diff-20260709-140656/71-mainline617-drmconsole-timeout-20260709.txt)
- [reports/lineage414-openela-diff-20260709-140656/72-mainline617-pstorebuilt-timeout-20260710.txt](reports/lineage414-openela-diff-20260709-140656/72-mainline617-pstorebuilt-timeout-20260710.txt)

## GitHub continuation

This repository is the GitHub continuation point for the local hotdog bring-up
workspace. The intended use is to keep the operational notes, scripts, and
small patches in Git while leaving large generated artifacts local.

For long hardware sessions, [scripts/start-stable-rescue-watcher.sh](scripts/start-stable-rescue-watcher.sh)
starts the rescue watcher as a detached process and keeps the stable image
available as a recovery target.

[scripts/show-stable-drm-pattern.sh](scripts/show-stable-drm-pattern.sh) can
start or collect the known-good KMS test pattern on an already booted stable
pmOS system.
