# Current boot cycle

Date: 2026-07-10 06:10 CEST

## Current Status

The phone is currently not commandable from the host after the latest display
console work. The user reported visible text on the screen, but the host still
has no USB recovery path or SSH at the time of this update.

```text
pmOS SSH: not reachable
fastboot: not visible
recovery ADB: not visible
ADB device: not visible
host lsusb: no phone/Qualcomm device detected
screen: visible text reported, not yet a host-commandable shell
companion rescue watcher: running, waiting for fastboot or recovery ADB
rescue supervisor: running, restarts a stable rescue watcher if the current one expires
pmOS SSH wait/test watcher: running, waiting for SSH before launching 061200
passive phone-state watcher: running, logging ADB/fastboot/USB and host kernel USB-log changes
autopilot hardening: duplicate rescue/supervisor starts now refused by default
USB rescue guard: running, no EDL writes, can run beside rescue-visible because fastboot restore now takes phone-operation.lock
```

Current validated boot image:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-215005-lineage414-drmconsole-initramfs-rootwatchdog-v2/boot-noefi-pmosdtb-watchdog-300s.img
sha256: 1075757fe6c7a582b94c4a9f837cd71b830d36da8e29c60acba85c49e6c57019
test log: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-215020
```

Default restore baseline boot image:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-215005-lineage414-drmconsole-initramfs-rootwatchdog-v2/boot-noefi-pmosdtb-watchdog-300s.img
sha256: 1075757fe6c7a582b94c4a9f837cd71b830d36da8e29c60acba85c49e6c57019
kernel sha256: dfac91230b3b2783fbd79408a5cd62f47bc2a86a4586347d814c5144d76d84d9
dtb pack sha256: b8ea3d9f87a290c0dc2d94d952442d249c11edaee141a29bc219317f08164bdf
```

Latest test result:

```text
test: downstream DRM-console image 215005
flash boot_b from pmOS SSH: OK
boot_b verification: OK
reboot command: issued from pmOS SSH
boot result: pmOS SSH returned
pmOS boot_id changed: 7854ea12-7415-41bc-8f2e-59d8865fd041
run log: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-215020/run.log
```

Latest mainline test:

```text
test: mainline 6.17 with PSTORE/RAMOOPS built in plus unmodified stock full DTB pack
image: /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-003000-mainline617-pstorebuilt-drmconsole-stockdtbpack-unmodified-watchdog/boot-noefi-pmosdtb-watchdog-420s.img
sha256: 87e62679c8f2aa7d1ce7df7cc7efec12ce2010a365becf99d2a323a85b7e712d
kernel sha256: 48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83
dtb pack sha256: f3afd969891fa461afe3bf61711863e6be3ba462d47e93794af1455b03253572
run log: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-10-003038/run.log
result: timeout after 720s, no fastboot/recovery ADB/pmOS SSH/USB device
rescue watcher: still running, waiting for target visibility
```

## DRM Console Milestone

The current image injects `hotdog-drm-console` into the initramfs and starts it
as soon as `/dev/dri/card0` is available. It stops the initramfs instance before
`switch_root`; the pmOS userspace hook then starts the persistent command
console.

Boot evidence:

```text
[    2.029100] [hotdog-drm-console] starting DRM dmesg console at initramfs after 0s
[    2.568984] [hotdog-watchdog] marker: usb-iface
[    5.570778] [hotdog-watchdog] marker: root-mounted
[    5.651583] [hotdog-watchdog] marker: switch-root
```

Visible shell evidence, sent from the host through the FIFO:

```text
command: scripts/install-hotdog-drm-console.sh send '... POST_BOOT_DRM_CONSOLE_OK ...'
transcript: /tmp/hotdog-drm-console.transcript on the phone
tty: /dev/pts/0
whoami: root
input FIFO: /tmp/hotdog-drm-console.in
```

## Display State

The downstream 4.14.357 boot continues to provide the working display path:

```text
/dev/dri/card0 and /dev/dri/renderD128 exist
DRM driver: MSM Snapdragon DRM / msm_drm
DSI-1: connected and enabled
connector id: 28
CRTC id: 136
preferred mode: #0, 1440x3120x60x187200
visible evidence: modetest -s 28@136:#0 -F smpte
```

The phone was previously reported black even though pmOS SSH was reachable.
Installing `libdrm-tests` and running a held `modetest` pattern proved that the
panel, KMS scanout, and backlight work on the downstream boot. The newer
`hotdog-drm-console` helper turns that evidence into a reusable text output
path.

Helper for reproducing the known-good visual pattern:

```text
/home/srobin/dev/hotdog/scripts/show-stable-drm-pattern.sh start
```

Helper for interacting with the visible DRM console on a booted pmOS system:

```text
/home/srobin/dev/hotdog/scripts/install-hotdog-drm-console.sh status
/home/srobin/dev/hotdog/scripts/install-hotdog-drm-console.sh send 'dmesg | tail -40'
/home/srobin/dev/hotdog/scripts/install-hotdog-drm-console.sh transcript 120
```

Evidence capture:

```text
/home/srobin/dev/hotdog/logs/live-drm-visible-20260709-211128/state.txt
```

`kmscube -D /dev/dri/card0` also completed through KMS/GBM/EGL, but Mesa used
`llvmpipe`, so that test validates scanout plus software EGL rather than Adreno
acceleration.

## Pstore

`pstore` is mounted on the recovered downstream boot, but it is empty after the
mainline 6.17 timeout tests, including the pstore-enabled kernel:

```text
pstore on /sys/fs/pstore type pstore (rw,nosuid,nodev,noexec,relatime)
/sys/fs/pstore: total 0
```

Implication: the failed mainline boot did not leave a readable ramoops/pstore
record even when `CONFIG_PSTORE=y` and `CONFIG_PSTORE_RAM=y` were built in. It
likely hung without panic, before the pstore backend could write, or before the
injected initramfs watchdog or DRM-console helper could run.

## Active Rescue Watcher

A detached rescue watcher is currently running for the latest mainline timeout.
It should restore the validated `215005` downstream DRM-console image if the
phone becomes visible in fastboot or recovery ADB. The first watcher for this
timeout stopped without restoring after its controlling output disappeared, so
the rescue script and launchers now support `HOTDOG_RESCUE_LOG_TEE=0` for
detached file-only logging.

Current watcher:

```text
pid: 1166999
watcher log: /home/srobin/dev/hotdog/logs/rescue-boot-b-when-visible-2026-07-10-005605/run.log
restore boot_b: /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-215005-lineage414-drmconsole-initramfs-rootwatchdog-v2/boot-noefi-pmosdtb-watchdog-300s.img
after restore: system
```

## Active Rescue Supervisor

A passive supervisor is also running so the rescue path does not silently expire
during a long session. It does not flash, reboot, sideload, or take the
phone-operation lock. It only starts a fresh stable rescue watcher when no
matching `rescue-boot-b-when-visible.sh` process exists:

```text
pid: 2080483
script: /home/srobin/dev/hotdog/scripts/watch-rescue-visible-supervisor.sh
log: /home/srobin/dev/hotdog/logs/manual-rescue-watchers/rescue-supervisor-stable-guard-current.log
restore boot_b: /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-215005-lineage414-drmconsole-initramfs-rootwatchdog-v2/boot-noefi-pmosdtb-watchdog-300s.img
after restore: system
supervisor timeout: 604800s
launched rescue timeout: 604800s
```

The scripts have also been hardened offline so future launches do not create
parallel rescue paths for the same phone by accident: the rescue watcher retries
if the phone-operation lock is busy, the stable watcher launcher serializes
starts per phone serial, and the supervisor holds a per-serial/label instance
lock.

The standalone fastboot restore helper now takes the same phone-operation lock,
and the USB rescue watcher has a per-serial/label instance lock. This lets a
long USB watcher run beside the existing fastboot/recovery ADB watcher without
creating a double-restore race. EDL writes remain disabled unless `--edl-write`
is passed explicitly.

## Active USB Rescue Guard

This watcher is complementary to the primary fastboot/recovery ADB rescue
watcher. It watches raw USB states too: fastboot, Qualcomm 9008, Qualcomm 900e,
and other Android/Qualcomm identities. EDL write mode is disabled; a 9008 sighting
will run validation only.

```text
pid: 2272770
run log: /home/srobin/dev/hotdog/logs/rescue-boot-b-when-usb-visible-2026-07-10-042926/run.log
pidfile: /home/srobin/dev/hotdog/logs/manual-rescue-watchers/usb-rescue-b6bd2252-host-usb-guard-current.pid
label: host-usb-guard
timeout: 604800s
poll: 5s
edl write: 0
```

## Active pmOS SSH Wait/Test Watcher

A detached wrapper is also waiting for pmOS SSH. It does not touch the phone
until SSH at `172.16.42.1` returns. If the rescue watcher restores `215005` and
pmOS SSH comes back, this wrapper launches the prepared `061200` test with
`--from-pmos-ssh`:

```text
pid: 1409621
launcher log: /home/srobin/dev/hotdog/logs/wait-and-test-lineage414-simplefb-shell-2026-07-10-013426/launcher.log
wrapper run log: /home/srobin/dev/hotdog/logs/wait-pmos-then-test-lineage414-simplefb-shell-2026-07-10-013426/run.log
script: /home/srobin/dev/hotdog/scripts/wait-pmos-then-test-next-lineage414-simplefb-shell.sh
next image: /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-061200-lineage414-r3-fbdevconsole-acmretry-visibletty-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img
restore image: /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-215005-lineage414-drmconsole-initramfs-rootwatchdog-v2/boot-noefi-pmosdtb-watchdog-300s.img
```

## Active Passive State Watcher

This watcher only snapshots host-visible state. It does not flash, reboot,
sideload, use SSH, or take the phone-operation lock.

```text
pid: 2464827
pidfile: /home/srobin/dev/hotdog/logs/watch-phone-state.pid
run log: /home/srobin/dev/hotdog/logs/watch-phone-state-2026-07-10-050641/run.log
latest summary: /home/srobin/dev/hotdog/logs/watch-phone-state-2026-07-10-050641/latest-summary.txt
timeout: 21600s
poll: 5s
```

In addition to `adb`, `fastboot`, `lsusb`, USB descriptors, and udev details,
the watcher now includes recent host kernel USB lines in `dmesg_usb=` and treats
changes there as new snapshots. This catches host-side enumeration/reset errors
even when `lsusb` stays empty.

## Prepared Kernel-Console Candidate

Built but not flashed yet because the phone is still not visible over USB.
The current automatic next candidate is `061200`. It supersedes `054356` and
the older `052210` path by keeping the `pkgrel=3` kernel/DTB/root watchdog/ACM
shape, but replacing the initramfs tty-kmsg experiment with a direct fbdev text
renderer. The helper now supports `--fbdev /dev/fb0`, loads a PSF font, renders
shell output directly into the framebuffer, follows dmesg every 4s, and stops
before `switch_root` so the rootfs visible tty shell can take over. Compared
with `060600`, it binds/retries the USB configfs UDC while waiting for `ttyGS0`.

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-061200-lineage414-r3-fbdevconsole-acmretry-visibletty-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img
sha256: 61677f02032308de88b5a08c64c0f3705d9b56c5c45481d5a2616a182991aa27
kernel override: /home/srobin/dev/hotdog/build/apk-extract/linux-oneplus-hotdog-lineage414-r3/boot/vmlinuz
kernel sha256: 8d542f8837950e20ecc17681c330c65303cb35e35345afe7e6a30cfc146c5df1
dtb pack: /home/srobin/dev/hotdog/build/apk-extract/linux-oneplus-hotdog-lineage414-r3/boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb
dtb pack sha256: 9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040
console helper sha256: b00ccd3b07751d4644242c195525c5d9d4e17709b77d70b27a0efd3cbb3362ec
base image: 215005 validated downstream 4.14 DRM-console boot image
options: --kernel pmaports-r3 --dtb fixed-entry12 --fbdev-console --usb-acm-getty --visible-tty-shell --visible-tty-autocycle --direct-debug-shell --with-ramoops-cmdline --watchdog-success root --strip-drm-console --extra-cmdline 'loglevel=8 ignore_loglevel fbcon=map:0 fbcon=font:VGA8x16 fbcon=vc:1-1'
initramfs sha256: 84873c5fe7dfb3b420d9a389db31e47ea0e7d9720c4f6abbe5168f314c3abfbf
expected new signal: fbdev-rendered initramfs dmesg/status text if /dev/fb0 appears, USB ACM serial shell if ttyGS0 enumerates after configfs/UDC retry, then a visible rootfs `screen#` page if switch_root succeeds.
```

DTB-pack verification note: the payload is a concatenated 20-entry Android DTB
pack. Plain `dtc -I dtb components/dtb` only shows entry 0 and is misleading
for this phone. Use:

```text
/home/srobin/dev/hotdog/scripts/inspect-dtb-pack-simplefb.sh \
  --dtb /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-061200-lineage414-r3-fbdevconsole-acmretry-visibletty-rootwatchdog/components/dtb \
  --entry 12
```

The verified `061200` entry 12 result is:

```text
entries=20
selected_entry=12
chosen_ranges=yes
stdout_path=yes
linux_stdout_path=yes
simplefb_compatible=yes
display0_alias=yes
```

## Fallback Downstream Console Candidate

The `014400` candidate remains the safer fallback because it keeps the known
booting `215005` kernel. It is useful if `015500` fails specifically because of
the kernel override, but it probably cannot show real kernel fbcon output
because the `215005` kernel lacks the relevant console config:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-014400-lineage414-simplefb-ranges-rebuilt-drmconsole-follow-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img
sha256: f99529e3e626b44734e58bc16cb8df7fcbf5efbc76e144c27f19b43d5ea5cd3b
dtb pack: /home/srobin/dev/hotdog/build/experiments/2026-07-10-010500-stock-dtb-pack-entry12-simplefb-ranges/stock-dtb-pack-entry12-simplefb-ranges-stdout.dtbpack
dtb pack sha256: 9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040
DRM helper sha256: 302fa020286d2c7941ad1d26c9d4d2ce775dad15665b49b56bdfde6f2b4b6b5b
base image: 215005 validated downstream 4.14 DRM-console boot image
options: --fb-test --drm-console-userspace --watchdog-success root
initramfs sha256: 899403669fdf5e9a42c8997cc648c66a4c7af9a67cd42bfb47611706e964a240
entry12 DTB change: add ranges; under /chosen and use absolute stdout-path strings; keep framebuffer reg size 0x1123800
console change: print one initial dmesg snapshot, keep a background `dmesg` follower, and leave `initramfs#` usable for FIFO commands
```

Superseded simplefb candidate:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-013100-lineage414-simplefb-ranges-rebuilt-drmconsole-shell-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img
sha256: bf7a6236e33a57f383d03daa490c054409b3529368c7b466dcd627199744faa2
reason superseded: command shell works, but the screen stops updating after the initial dmesg snapshot if there is no USB/FIFO input.

/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-011900-lineage414-simplefb-ranges-fbtest-drmconsole-shell-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img
sha256: 2855c26423300eefca569c8f19f232494a5a84296af38441b43e161e1323e262
reason superseded: behaviorally similar to 013100, but built before the helper rebuild path existed.

/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-010900-lineage414-simplefb-ranges-fbtest-drmconsole-userspace-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img
sha256: 20ca331fd98c8f8a512574ed5984bc683716716b43348f977befac0dbe8f70fe
reason superseded: initramfs DRM console stayed in a foreground dmesg loop, so it displayed text but was not a useful command prompt.
```

Older prepared userspace-console-only candidate:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-005100-lineage414-drmconsole-userspace-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img
sha256: 646d5967ed6edfaf667209fa5601cf04ea69fd4bc0b4961f316f0b2a16cbeaf0
base image: 215005 validated downstream 4.14 DRM-console boot image
new option: --drm-console-userspace
effect: before switch_root, copy hotdog-drm-console plus font into /sysroot and install /etc/local.d/hotdog-drm-console.start
```

Purpose: keep the known-good downstream path as the visible baseline, but remove
the dependency on a manually pre-installed userspace DRM console. If this image
boots to the rootfs, the screen-side command shell should be restored by OpenRC
`local.d` even on a cleaner pmOS rootfs.

The `005100` image is still not true kernel-early text. Existing downstream evidence shows
`/dev/fb0` absent and `simple-framebuffer chosen:framebuffer@9c000000: No
memory resource`; the reliable screen path is the DRM/KMS helper after
`/dev/dri/card0` appears. Offline inspection found that the earlier
multi-DTB-pack entry12 simplefb node was missing `ranges;` below `/chosen`,
while older single-DTB experiments that looked healthier did include it. The
`014400` image is the isolated ramdisk/DTB-only fallback for that fix, while
`060600` tests the pmaports r3 kernel plus direct fbdev text rendering for the
next screen-only diagnostic path. It keeps the visible rootfs tty shell and USB
ACM fallback. `025400` remains the stricter no-DRM-helper fbcon isolation test.

## Last Mainline Test

Tested image:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-003000-mainline617-pstorebuilt-drmconsole-stockdtbpack-unmodified-watchdog/boot-noefi-pmosdtb-watchdog-420s.img
sha256: 87e62679c8f2aa7d1ce7df7cc7efec12ce2010a365becf99d2a323a85b7e712d
kernel sha256: 48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83
dtb pack sha256: f3afd969891fa461afe3bf61711863e6be3ba462d47e93794af1455b03253572
initramfs: watchdog plus DRM-console helper
kernel config: CONFIG_PSTORE=y, CONFIG_PSTORE_RAM=y, CONFIG_PSTORE_CONSOLE=y
```

Run log:

```text
/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-10-003038/run.log
```

Result:

```text
flash boot_b from pmOS SSH: OK
boot_b verification: OK
reboot observed: USB ping dropped
boot result after 720s: timeout
fastboot/recovery ADB/pmOS SSH: none
host lsusb during timeout: no phone device
rescue watcher: left running
```

Interpretation:

```text
The bootloader accepted the image well enough not to immediately return to
fastboot, but the kernel did not reach a recoverable USB path. Replacing the
entry12 simplefb/stdout-path DTB pack with the unmodified stock full DTB pack
did not change the failure mode. The hang is probably below initramfs-side
instrumentation, around kernel entry, early exception handling, GIC/SRE/EL2, or
PSCI.
```

## Next Useful Work

1. Keep the downstream 4.14 DRM-console image as the visible baseline for fast
   recovery and phone-side inspection.
2. Treat the mainline timeout as pre-initramfs/pre-pstore or pre-DRM until
   there is evidence that `/init` starts.
3. Test the prepared downstream `060600` image once the phone is back in a
   commandable state. It keeps the `pkgrel=3` pmaports kernel/DTB/cmdline shape,
   but replaces the fragile initramfs tty-kmsg path with a direct fbdev PSF text
   console on `/dev/fb0`. That should show dmesg/status as soon as fb0 exists
   even if fbcon never takes over the boot console. It also keeps direct telnet
   after USB networking, USB ACM `ttyGS0` getty fallback, and the rootfs visible
   tty auto-cycle shell after `switch_root`.
   Expected observations: fbdev-rendered initramfs text if `/dev/fb0` appears,
   then a tty1/tty0 rootfs status page plus a `screen#` prompt if rootfs is
   reached. If USB ACM enumerates, the host watcher captures `/dev/ttyACM*`.
4. The fixed entry12 `ranges;` DTB pack has already been promoted into the
   local downstream 4.14 pmaports package. The current local package is
   `pkgrel=3`, adds USB CDC ACM gadget support, and was validated with
   `pmbootstrap checksum linux-oneplus-hotdog-lineage414` plus an APK rebuild.
   The next test keeps the same fixed DTB pack and only changes the kernel
   config plus initramfs/rootfs access hooks.
5. Keep using `scripts/build-hotdog-drm-console-helper.sh` to regenerate the
   AArch64 DRM helper before building display-console candidates on a fresh
   host.
6. Run `scripts/validate-current-candidates.sh` before the next hardware cycle
   after changing wrappers, DTB packs, cmdline, or initramfs helper generation.
   It validates the current `061200` next candidate, `034200`, and `025400`
   without phone commands.
7. The prepared wrapper for the next test is
   `scripts/test-next-lineage414-simplefb-shell.sh`; if pmOS SSH returns first,
   use `scripts/wait-pmos-then-test-next-lineage414-simplefb-shell.sh`.
8. For mainline, stop treating USB gadget alone as the first milestone. The
   next useful signal is kernel-entry evidence, a bootloader-visible return
   reason, or initramfs reachability through a channel earlier than USB gadget.
9. A mainline RAM-marker candidate is prepared at `022522`. Use it when the
   objective is to identify how far `arch/arm64/kernel/head.S` progresses:
   it writes `ENT1`/`ENT2`/`SWT3` into the existing `0xa9800000` ramoops dump
   window and can be launched with `scripts/test-next-mainline617-rammarker.sh`.
   From a booted pmOS SSH baseline, use
   `scripts/wait-pmos-then-test-next-mainline617-rammarker.sh`.
   If recovery ADB returns afterwards, `collect-recovery-crash-artifacts.sh`
   now emits `ramoops-marker-scan.txt` with marker offsets when the raw
   `/dev/mem` dump is available.
10. Do not retest the exact `192100`, `220500`, or `224100` mainline 6.17 images
   without a new kernel/DTB hypothesis.

Prepared downstream fbdev-console/screen-shell/USB-ACM candidate:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-061200-lineage414-r3-fbdevconsole-acmretry-visibletty-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img
sha256: 61677f02032308de88b5a08c64c0f3705d9b56c5c45481d5a2616a182991aa27
kernel sha256: 8d542f8837950e20ecc17681c330c65303cb35e35345afe7e6a30cfc146c5df1
dtb pack sha256: 9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040
initramfs sha256: 84873c5fe7dfb3b420d9a389db31e47ea0e7d9720c4f6abbe5168f314c3abfbf
helper sha256: b00ccd3b07751d4644242c195525c5d9d4e17709b77d70b27a0efd3cbb3362ec
wrapper: /home/srobin/dev/hotdog/scripts/test-next-lineage414-simplefb-shell.sh
fbdev console: yes, initramfs helper waits for /dev/fb0, prepares mode/backlight/font, renders dmesg/status directly into the framebuffer, and stops before switch_root
tty kmsg console: no, replaced by direct fbdev rendering for the next test
visible tty shell: yes, local.d hook starts `hotdog-visible-tty-shell` on tty1/tty0 after switch_root; Vol+ prints full status, Vol- prints network/display status, Power prints a dmesg tail; autocycle=1 rotates full/network/dmesg pages every 12s while keeping a `screen#` prompt if input exists
USB ACM serial fallback: yes, initramfs `hotdog_usb_acm_getty.sh` calls pmOS `setup_usb_acm_configfs`, starts a getty on `ttyGS0`, and rootfs local.d repeats the `ttyGS0` shell setup after switch_root
direct telnet fallback: yes, starts after USB networking if the network gadget becomes usable
watchdog: root-mounted/switch-root success mode, sysrq reboot first on timeout
```

Prepared secondary splash/fbprep candidate:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-034200-lineage414-pmaports-kernel-splash-ttykmsg-fbprep-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img
sha256: 51c0d12333407d31a01a3a7f5f3669a23bf5dfe4b9da4b850f2ac3e4c1cc0934
kernel sha256: c6411a83cc004d52209b39d9ac6fa552d93b5be719bbaa0536060c78e4d4266e
dtb pack sha256: 9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040
initramfs sha256: cb93effcaa53091bc1266d9cbb5d53b5995f0604910a5174135dca317f9dc4d3
cmdline extra: splash
wrapper: /home/srobin/dev/hotdog/scripts/test-lineage414-splash-ttykmsg.sh
purpose: force the normal pmOS initramfs setup_framebuffer path in addition to the tty-kmsg/fbprep helper
```

Prepared secondary fbcon-only isolation candidate:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-025400-lineage414-pmaports-kernel-fbcon-only-fbtest-stripdrm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img
sha256: aa176c852c3fe359839d18d80ff5d68f5ff0edaa2584c98e96362976083f8fca
kernel sha256: c6411a83cc004d52209b39d9ac6fa552d93b5be719bbaa0536060c78e4d4266e
dtb pack sha256: 9ed26b5cc289633ae1b98ce3212a084d673779fb188307a442f4922588032040
initramfs sha256: 496618344e3b3eda03c8bab22b33aec232c3a87613e08eebd401ae74e37c6a4a
wrapper: /home/srobin/dev/hotdog/scripts/test-lineage414-fbcon-only.sh
purpose: isolate kernel/simplefb/fbcon output by stripping inherited DRM-console hooks
```

Prepared mainline RAM-marker candidate:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-10-022522-mainline617-rammarker-stockdtbpack-drmconsole-watchdog/boot-noefi-pmosdtb-watchdog-420s.img
sha256: 545b21b1f626586b6ce4cbc36ab4ee81cfd23451421af4fb383128cc916f0e4d
kernel sha256: 4cf970840c91e8ddd9c1e0b9051ac1955ad6a7fb0244d776254fcc05c4ad6063
dtb pack sha256: f3afd969891fa461afe3bf61711863e6be3ba462d47e93794af1455b03253572
wrapper: /home/srobin/dev/hotdog/scripts/test-next-mainline617-rammarker.sh
wait wrapper: /home/srobin/dev/hotdog/scripts/wait-pmos-then-test-next-mainline617-rammarker.sh
```

Previous minimal mainline candidate that led to the DRM-console follow-up:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-204605-mainline617-minramdisk-pstore-stockdtbpack-entry12-watchdog/boot-noefi-pmosdtb-watchdog-420s.img
sha256: 46e00544c908530944ed0edb3b96454e38f229e8ec4954dcd59cd756e9c2bd02
kernel sha256: 84f33a57aa1f32bcf938d7e9f85e0f3acc2dbf159c8aaed8534e2f13a6fc4004
dtb pack sha256: b8ea3d9f87a290c0dc2d94d952442d249c11edaee141a29bc219317f08164bdf
initramfs sha256: e6676fa9a83f88334bee919204b491c5c1eab3ce48564c9b3e28050dd38eb65f
wrapper: /home/srobin/dev/hotdog/scripts/test-next-mainline617-minramdisk-pstore.sh
```

This candidate removes the direct debug shell and framebuffer paint test from
the failed `192100` shape while keeping mainline 6.17, the same stock DTB pack,
ramoops/pstore cmdline, and the root-mode watchdog.

## Reports

High-signal notes:

```text
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/66-devtmpfs-drm-plymouth-display-20260709.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/67-mainline617-timeout-20260709.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/68-mainline617-minramdisk-candidate-20260709.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/69-drm-visible-pattern-20260709.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/70-drm-console-shell-initramfs-20260709.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/71-mainline617-drmconsole-timeout-20260709.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/72-mainline617-pstorebuilt-timeout-20260710.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/73-mainline617-stockdtbpack-timeout-20260710.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/79-mainline-entry-ram-marker-probe-20260710.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/80-mainline617-rammarker-candidate-20260710.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/81-drm-console-button-input-candidate-20260710.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/82-drm-console-button-rescan-candidate-20260710.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/83-fbcon-only-stripdrm-candidate-20260710.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/84-recovery-rammarker-scan-20260710.txt
```
