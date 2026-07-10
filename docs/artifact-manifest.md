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
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-215005-lineage414-drmconsole-initramfs-rootwatchdog-v2/boot-noefi-pmosdtb-watchdog-300s.img` | Current validated downstream pmOS boot image. It boots to SSH over USB, starts the initramfs DRM console, then starts the userspace visible command shell. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-034500-lineage414-pmaports-kernel-ttykmsg-buttonshell-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Current next downstream 4.14 pmaports-kernel screen candidate. It keeps the `033600` kernel/DTB path, raises `loglevel=8`, keeps all `fbcon=` args, and adds a rootfs visible tty button console: Vol+ full status, Vol- network/display status, Power dmesg tail. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-034200-lineage414-pmaports-kernel-splash-ttykmsg-fbprep-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Secondary downstream 4.14 screen candidate. It keeps the `033600` hooks and additionally appends `splash` so pmOS runs its normal initramfs `setup_framebuffer()` path before starting Plymouth/splash. Use after `034500` if fb0/fbcon still looks timing-gated. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-033600-lineage414-pmaports-kernel-ttykmsg-fbprep-screen-shell-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Superseded downstream 4.14 pmaports-kernel console candidate. It keeps the `030600` kernel/DTB/cmdline shape, adds an initramfs `/dev/tty0` kmsg/status follower before the DRM helper, waits for `/dev/fb0`, sets an empty framebuffer mode when possible, boosts backlight, and installs the rootfs `hotdog-visible-tty-shell` local.d hook after `switch_root`. Superseded by `034500`, which makes the visible tty rootfs console button-controllable. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-030600-lineage414-pmaports-kernel-screen-shell-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Superseded downstream 4.14 pmaports-kernel console candidate. It keeps the `024200` kernel/DTB/cmdline shape, keeps DRM helper Vol+/Vol- diagnostics, and adds a rootfs `hotdog-visible-tty-shell` local.d hook so a tty1/tty0 shell prompt plus status follower appears on screen after `switch_root`. Superseded by `033600`, then `034500`. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-024200-lineage414-pmaports-kernel-fbcon-drmconsole-buttons-rescan-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Superseded downstream 4.14 pmaports-kernel console candidate. It keeps the `015500` kernel/DTB/cmdline shape for visible kernel/fbcon output and adds a DRM helper that can queue diagnostics from Vol+/Vol- and rescan `/dev/input/event*` while running. Superseded by `030600`, then `033600`. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-025400-lineage414-pmaports-kernel-fbcon-only-fbtest-stripdrm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Secondary downstream 4.14 pmaports-kernel fbcon isolation candidate. It keeps the same kernel/DTB/cmdline as `033600`, `030600`, and `024200`, keeps the framebuffer paint test, and strips inherited DRM-console hooks from the `215005` source initramfs so kernel/simplefb/fbcon output is not masked by the helper. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-023410-lineage414-pmaports-kernel-fbcon-drmconsole-buttons-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Superseded downstream 4.14 pmaports-kernel console candidate. It first added local Vol+/Vol- diagnostics to the DRM helper, but only opened `/dev/input/event*` once at startup. Superseded by `024200`, which rescans input devices while running. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-015500-lineage414-pmaports-kernel-fbcon-drmconsole-autodiag-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Superseded downstream 4.14 pmaports-kernel console candidate. Built from `215005` ramdisk shape but overrides the kernel with the `pkgrel=2` pmaports `vmlinuz`, overrides the DTB pack with fixed entry12 `/chosen ranges;`, keeps `--fb-test`, installs the DRM command console, and uses the helper with an automatic userspace status follower. Superseded by `023410`, `024200`, `030600`, then `033600`. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-022522-mainline617-rammarker-stockdtbpack-drmconsole-watchdog/boot-noefi-pmosdtb-watchdog-420s.img` | Prepared mainline 6.17 RAM-marker candidate. It keeps the `003000` stock full DTB pack/cmdline/DRM-console shape, but swaps in a kernel that writes `ENT1`/`ENT2`/`SWT3` into the `0xa9800000` ramoops dump window from early `head.S`. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-014400-lineage414-simplefb-ranges-rebuilt-drmconsole-follow-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Safer downstream 4.14 simplefb/fbcon fallback image. Built from `215005`; overrides only the DTB pack/initramfs path, enables `--fb-test`, starts an initramfs DRM command shell, runs a background `dmesg` follower every 5s, and auto-installs the userspace DRM command console. It keeps the known-good `215005` kernel, so it is less likely to expose kernel-side VT/fbcon output. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-013100-lineage414-simplefb-ranges-rebuilt-drmconsole-shell-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Superseded downstream 4.14 simplefb/fbcon command-shell candidate. It is behaviorally similar to `014400`, but only prints one initramfs dmesg snapshot instead of following dmesg in the background. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-011900-lineage414-simplefb-ranges-fbtest-drmconsole-shell-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Superseded downstream 4.14 simplefb/fbcon command-shell candidate. It is behaviorally similar to `013100`, but was built before the helper rebuild path was added. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-010900-lineage414-simplefb-ranges-fbtest-drmconsole-userspace-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Superseded downstream 4.14 simplefb/fbcon candidate. It used the same fixed DTB pack, but its initramfs DRM console stayed in a foreground `dmesg` loop instead of returning to a command prompt. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-005100-lineage414-drmconsole-userspace-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img` | Prepared downstream 4.14 follow-up image. Built from `215005`; adds `--drm-console-userspace` so the initramfs installs the visible DRM command console into the mounted rootfs before `switch_root`. Not flashed yet. |
| `/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-195300-lineage414-devtmpfs-drmfbdev-fbtest-pstore-stockdtbpack-entry12-watchdog/boot-noefi-pmosdtb-watchdog-180s.img` | Older restore-baseline pmOS boot image. It boots to SSH over USB and auto-starts the earlier DRM/Plymouth display hook, but the default restore target is now `215005`. |
| `/home/srobin/dev/hotdog/images/lineage/hotdog-20260703/recovery-adb-unsecure.img` | Patched recovery image used for recovery-side ADB. |
| `/home/srobin/dev/hotdog/tools/recovery-zips/build/hotdog-reboot-bootloader.zip` | Sideload package for returning the device to bootloader. |

## High-signal logs

| Path | Purpose |
|---|---|
| `/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-215020` | Validated downstream DRM-console boot. pmOS SSH returned with boot id `7854ea12-7415-41bc-8f2e-59d8865fd041`; initramfs console marker appears at 2.029100s. |
| `/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-220520` | Mainline 6.17 minimal/pstore plus DRM-console test. Timed out after 720s with no USB recovery path; manual fastboot recovery later restored the downstream image. |
| `/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-224052` | Mainline 6.17 rebuilt with built-in PSTORE/RAMOOPS plus DRM-console test. Timed out after 720s with no USB recovery path; pstore was still empty after recovery. |
| `/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-10-003038` | Mainline 6.17 pstore-built test with unmodified stock full DTB pack. Timed out after 720s with no USB recovery path; companion rescue watcher left running. |
| `/home/srobin/dev/hotdog/logs/rescue-boot-b-when-visible-2026-07-10-003053` | First rescue watcher for the `003038` timeout; stopped without seeing USB/fastboot/recovery and without restoring. |
| `/home/srobin/dev/hotdog/logs/rescue-boot-b-when-visible-2026-07-10-005605` | Active file-only detached rescue watcher for the `003038` timeout; restores the validated `215005` downstream image if fastboot or recovery ADB returns. |
| `/home/srobin/dev/hotdog/logs/flash-boot-b-from-pmos-ssh-2026-07-09-223252` | Post-recovery writeback of the validated `215005` DRM-console image to `boot_b` without reboot. |
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
| `/home/srobin/dev/hotdog/patches/experimental-mainline-entry-psci-reset-probe.patch` | Disposable mainline probe patch. It makes `primary_entry` immediately call PSCI SYSTEM_RESET through `smc #0`, to distinguish bootloader handoff failure from kernel-entry/early-exception failure. Do not apply to normal boot builds. |
| `/home/srobin/dev/hotdog/patches/experimental-mainline-entry-ram-marker-probe.patch` | Preferred disposable mainline early-entry probe. It writes `ENT1`, `ENT2`, and `SWT3` into the existing `0xa9800000` ramoops window so recovery-side `/dev/mem` dumps can show how far `head.S` progressed without USB/initramfs/pstore. |
| `/home/srobin/dev/hotdog/aports/device/testing/linux-oneplus-hotdog-lineage414` | Tracked snapshot of the local downstream 4.14 aport, including the fixed `stock-hotdog-dtbpack.dtb` with SHA256 `9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040`. Use this to seed or compare a fresh `pmaports-sm8150` checkout. |
| `/home/srobin/dev/hotdog/src/postmarketos/pmaports-sm8150` | Local pmaports fork with the hotdog device package. |
| `/home/srobin/dev/hotdog/src/kernel/linux-postmarketos-qcom-sm8150-v6.17.0-sm8150` | Mainline/postmarketOS kernel work tree used for the current experiments. |
| `/home/srobin/dev/hotdog/src/lineage/android_kernel_oneplus_sm8150` | Lineage kernel source checkout used for comparison. |
| `/home/srobin/dev/hotdog/scripts/build-entry12-simplefb-ranges-dtbpack.sh` | Rebuilds the fixed entry12 simplefb `ranges;` DTB pack used by the prepared `014400`, `015500`, `024200`, `030600`, `033600`, `034200`, and `034500` images. |
| `/home/srobin/dev/hotdog/scripts/inspect-dtb-pack-simplefb.sh` | Splits and inspects a single DTB or concatenated Android DTB pack. Use this instead of plain `dtc` when checking whether selected entry `12` has `/chosen` `ranges;`, `stdout-path`, and `simple-framebuffer`. |
| `/home/srobin/dev/hotdog/scripts/build-hotdog-drm-console-helper.sh` | Rebuilds `helpers/hotdog-drm-console.c` as an AArch64 Alpine/pmOS binary through the pmbootstrap aarch64 buildroot. `build-watchdog-bootimg.sh` calls it automatically if the default helper is missing. Latest helper SHA256 `4aec4bca3b6849fbb31a826adddce781146400bb3676b8503b387bc41dc8ffe8`. |
| `/home/srobin/dev/hotdog/scripts/test-next-mainline617-rammarker.sh` | Manual test wrapper for the prepared `022522` mainline RAM-marker candidate. It starts the normal rescue watcher and restores the validated downstream `215005` image when fastboot/recovery ADB returns. |
| `/home/srobin/dev/hotdog/scripts/wait-pmos-then-test-next-mainline617-rammarker.sh` | Waits for pmOS SSH, then launches the `022522` mainline RAM-marker test from the booted pmOS system with `--from-pmos-ssh`. |
| `/home/srobin/dev/hotdog/scripts/collect-recovery-crash-artifacts.sh` | Recovery-ADB collector used by rescue/test wrappers after failed boots. It attempts pstore and raw `0xa9800000` ramoops-window reads and now writes `ramoops-marker-scan.txt` to report any `ENT1`/`ENT2`/`SWT3` RAM-marker hits. |
| `/home/srobin/dev/hotdog/scripts/sync-aport-snapshots.sh` | Check or copy tracked aport snapshots under `aports/` into the local `pmaports-sm8150` checkout. Default is check-only; use `--apply` on a fresh machine. |
| `/home/srobin/dev/hotdog/scripts/test-next-lineage414-simplefb-shell.sh` | Wrapper for the next `034500` hardware test. It restores `boot_b` to `215005` and starts a companion rescue watcher. |
| `/home/srobin/dev/hotdog/scripts/test-lineage414-splash-ttykmsg.sh` | Manual wrapper for the secondary `034200` splash/fbprep screen test. It restores `boot_b` to `215005` and starts a companion rescue watcher, but it is not the automatic next test. |
| `/home/srobin/dev/hotdog/scripts/test-lineage414-fbcon-only.sh` | Manual wrapper for the secondary `025400` fbcon-only isolation test. It restores `boot_b` to `215005` and starts a companion rescue watcher, but it is not the automatic next test. |
| `/home/srobin/dev/hotdog/scripts/wait-pmos-then-test-next-lineage414-simplefb-shell.sh` | Waits for pmOS SSH, then launches the current downstream pmaports/fbcon test from the booted pmOS system with `--from-pmos-ssh`. |
| `/home/srobin/dev/hotdog/src/postmarketos/pmaports-sm8150/device/testing/linux-oneplus-hotdog-lineage414` | Local downstream 4.14 aport. The local copy has `pkgrel=2` and `stock-hotdog-dtbpack.dtb` updated to the fixed entry12 `/chosen ranges;` DTB pack; `pmbootstrap checksum linux-oneplus-hotdog-lineage414` validated the SHA512 on 2026-07-10 01:15 CEST. |
| `/home/srobin/dev/hotdog/pmbootstrap-work/packages/edge/aarch64/linux-oneplus-hotdog-lineage414-4.14.357_git20260703-r2.apk` | Built downstream 4.14 kernel package from the local `pkgrel=2` aport after the fixed DTB-pack promotion. SHA256 `f50f98ee251f1f4658aba1ea6bfc8141db79359485e0b15076370c19702482ff`. |

## Report set

| Path | Purpose |
|---|---|
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/99-report-index.txt` | Entry point for the current diff and analysis bundle. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/60-boot-test-findings-20260709.txt` | Boot-test findings and conclusions. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/66-devtmpfs-drm-plymouth-display-20260709.txt` | Downstream devtmpfs/DRM/Plymouth display milestone. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/67-mainline617-timeout-20260709.txt` | Mainline 6.17 timeout result and implication. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/68-mainline617-minramdisk-candidate-20260709.txt` | Prepared minimal mainline 6.17 follow-up candidate. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/69-drm-visible-pattern-20260709.txt` | Visible downstream KMS pattern result and next `--drm-test` recommendation. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/70-drm-console-shell-initramfs-20260709.txt` | Downstream initramfs DRM console and userspace visible command-shell milestone. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/71-mainline617-drmconsole-timeout-20260709.txt` | Mainline 6.17 with DRM-console instrumentation timed out before any visible or USB recovery signal. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/72-mainline617-pstorebuilt-timeout-20260710.txt` | Mainline 6.17 with built-in pstore/ramoops still timed out without visible, USB, or pstore signal. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/73-mainline617-stockdtbpack-timeout-20260710.txt` | Mainline 6.17 pstore-built with the unmodified stock full DTB pack still timed out, ruling out the entry12 simplefb/stdout DTB-pack modification as the main cause. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/74-drm-console-userspace-candidate-20260710.txt` | Prepared downstream 4.14 image that auto-installs the DRM command console into rootfs, plus rescue watcher robustness fix. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/75-simplefb-ranges-candidate-20260710.txt` | Offline root cause for simplefb `No memory resource`; prepared `010900` image with fixed entry12 `/chosen ranges;`, fb-test, and userspace DRM console. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/76-drm-command-shell-candidate-20260710.txt` | Follow-up image `014400` changes the initramfs DRM console from a foreground `dmesg` loop into a command shell with a background `dmesg` follower, records the local pmaports DTB-pack promotion, and uses a helper rebuilt from source. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/77-pmaports-kernel-fbcon-candidate-20260710.txt` | Prepared image `015500` promotes the pmaports `pkgrel=2` kernel into the boot image to test VT/fbcon/simplefb kernel output on screen while keeping the DRM-console watchdog path. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/78-mainline-entry-reset-probe-20260710.txt` | Offline mainline entry-probe plan using PSCI SYSTEM_RESET at `primary_entry`. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/79-mainline-entry-ram-marker-probe-20260710.txt` | Offline mainline early-entry probe that writes `ENT1`/`ENT2`/`SWT3` into the existing `0xa9800000` ramoops dump window. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/80-mainline617-rammarker-candidate-20260710.txt` | Prepared boot image `022522` using the mainline RAM-marker kernel plus the previously tested stock full DTB pack. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/81-drm-console-button-input-candidate-20260710.txt` | Prepared boot image `023410` using the pmaports 4.14 fbcon candidate plus a DRM console helper that maps Vol+/Vol- to diagnostics. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/82-drm-console-button-rescan-candidate-20260710.txt` | Prepared boot image `024200` using the same pmaports 4.14 fbcon candidate plus a DRM console helper that rescans local input devices while running. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/83-fbcon-only-stripdrm-candidate-20260710.txt` | Prepared boot image `025400` for the secondary no-DRM-helper fbcon/simplefb isolation test. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/84-recovery-rammarker-scan-20260710.txt` | Added automatic `ENT1`/`ENT2`/`SWT3` scan output to the recovery crash collector. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/85-mainline-rammarker-wait-wrapper-20260710.txt` | Added pmOS SSH wait wrapper for the `022522` mainline RAM-marker test and clarified collector help for raw ramoops marker scans. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/86-dtb-pack-entry12-verification-20260710.txt` | Added the DTB-pack entry inspector and verified that `030600` entry `12` contains `/chosen` `ranges;`, `stdout-path`, `linux,stdout-path`, `display0`, and `simple-framebuffer`. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/87-tty-kmsg-screen-candidate-20260710.txt` | Prepared boot image `033600`, which adds an initramfs tty0/tty1 kmsg/status follower plus fb0/backlight preparation before the DRM helper while preserving the verified pmaports kernel and entry12 simplefb DTB pack. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/88-splash-ttykmsg-secondary-20260710.txt` | Prepared secondary boot image `034200`, which appends `splash` to exercise the normal pmOS initramfs framebuffer setup path before the same tty-kmsg/fbprep diagnostics. |
| `/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/89-button-visible-tty-candidate-20260710.txt` | Prepared boot image `034500`, which keeps the `033600` pmaports kernel/DTB path and makes the rootfs visible tty console controllable through Vol+/Vol-/Power. |

## Resume order

1. Clone the repo on the new machine.
2. Run `./scripts/bootstrap-host.sh`.
3. Copy `pmbootstrap_v3.cfg.example` to `pmbootstrap_v3.cfg` and adjust local
   paths if needed.
4. Restore any required local artifacts from the manifest, or rebuild them with
   the scripts already in the repo.
5. Use `./scripts/install-hotdog-drm-console.sh status` and
   `./scripts/install-hotdog-drm-console.sh send 'dmesg | tail -40'` to confirm
   the visible console once pmOS SSH is reachable.
6. Re-run `./scripts/bootstrap-host.sh --check-host` before you pick up the next
   device step.
