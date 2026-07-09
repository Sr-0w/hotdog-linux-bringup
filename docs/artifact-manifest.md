# Artifact manifest

Curated pointers to the local artifacts that matter when resuming work on
another machine. These paths are intentionally local and are not meant to be
committed as raw binaries in the normal Git history.

If you move to a new PC, treat the entries below as machine-local pointers:
clone the repo, run `./scripts/bootstrap-host.sh`, then restore or regenerate
only the artifacts you actually need.

## Stable boot and recovery assets

| Path | Purpose |
|---|---|
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-195300-lineage414-devtmpfs-drmfbdev-fbtest-pstore-stockdtbpack-entry12-watchdog/boot-noefi-pmosdtb-watchdog-180s.img` | Current stable pmOS boot image that boots to SSH over USB and auto-starts the DRM/Plymouth display hook. |
| `/home/srobin/dev/hotdog/images/lineage/hotdog-20260703/recovery-adb-unsecure.img` | Patched recovery image used for recovery-side ADB. |
| `/home/srobin/dev/hotdog/tools/recovery-zips/build/hotdog-reboot-bootloader.zip` | Sideload package for returning the device to bootloader. |

## High-signal logs

| Path | Purpose |
|---|---|
| `/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-201112` | Latest confirmed stable pmOS boot with automatic DRM/Plymouth hook. |
| `/home/srobin/dev/hotdog/logs/live-pmos-2014-auto-plymouth/state.txt` | Captured stable pmOS state with DSI-1 enabled and plymouthd alive. |
| `/home/srobin/dev/hotdog/logs/live-drm-visible-20260709-211128/state.txt` | Captured stable pmOS state after a visible `modetest` SMPTE pattern on DSI-1. |
| `/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-202324` | Mainline 6.17 test that timed out without USB/fastboot/recovery return. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-204605-mainline617-minramdisk-pstore-stockdtbpack-entry12-watchdog/boot-noefi-pmosdtb-watchdog-420s.img` | Prepared minimal mainline 6.17 follow-up candidate; not yet tested. |
| `/home/srobin/dev/hotdog/logs/current-stall-summary.txt` | Quick human-readable summary of the current blocker. |

## Source and patch anchors

| Path | Purpose |
|---|---|
| `/home/srobin/dev/hotdog/patches/experimental-android-kernel-header-text-offset.patch` | Local kernel header experiment kept outside the source checkouts. |
| `/home/srobin/dev/hotdog/src/postmarketos/pmaports-sm8150` | Local pmaports fork with the hotdog device package. |
| `/home/srobin/dev/hotdog/src/kernel/linux-postmarketos-qcom-sm8150-v6.17.0-sm8150` | Mainline/postmarketOS kernel work tree used for the current experiments. |
| `/home/srobin/dev/hotdog/src/lineage/android_kernel_oneplus_sm8150` | Lineage kernel source checkout used for comparison. |

## Report set

| Path | Purpose |
|---|---|
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/99-report-index.txt` | Entry point for the current diff and analysis bundle. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/60-boot-test-findings-20260709.txt` | Boot-test findings and conclusions. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/66-devtmpfs-drm-plymouth-display-20260709.txt` | Downstream devtmpfs/DRM/Plymouth display milestone. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/67-mainline617-timeout-20260709.txt` | Mainline 6.17 timeout result and implication. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/68-mainline617-minramdisk-candidate-20260709.txt` | Prepared minimal mainline 6.17 follow-up candidate. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/69-drm-visible-pattern-20260709.txt` | Visible downstream KMS pattern result and next `--drm-test` recommendation. |

## Resume order

1. Clone the repo on the new machine.
2. Run `./scripts/bootstrap-host.sh`.
3. Copy `pmbootstrap_v3.cfg.example` to `pmbootstrap_v3.cfg` and adjust local
   paths if needed.
4. Restore any required local artifacts from the manifest, or rebuild them with
   the scripts already in the repo.
5. Use `./scripts/show-stable-drm-pattern.sh start` to reproduce the known-good
   stable KMS output once pmOS SSH is reachable.
6. Re-run `./scripts/bootstrap-host.sh --check-host` before you pick up the next
   device step.
