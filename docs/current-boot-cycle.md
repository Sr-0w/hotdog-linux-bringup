# Current boot cycle

Date: 2026-07-10 00:22 CEST

## Current Status

The phone is recovered to downstream Lineage/OpenELA 4.14.357 pmOS after the
latest mainline timeout. USB SSH is reachable, the userspace DRM console is
running, and `boot_b` is verified as the validated DRM-console image.

```text
pmOS SSH: user@172.16.42.1 reachable
live boot_id: 5a6cd93e-28c5-47dc-84fe-119534c8b2e1
kernel: Linux hotdog 4.14.357-openela-perf #2-postmarketOS
DSI-1: enabled
visible test: userspace DRM text console plus command-output transcript on DSI-1
USB network: usb0 on the phone, 172.16.42.1/16
boot_b after recovery: verified as the validated 215005 DRM-console image
```

Current validated boot image:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-215005-lineage414-drmconsole-initramfs-rootwatchdog-v2/boot-noefi-pmosdtb-watchdog-300s.img
sha256: 1075757fe6c7a582b94c4a9f837cd71b830d36da8e29c60acba85c49e6c57019
test log: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-215020
```

Restore baseline boot image:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-195300-lineage414-devtmpfs-drmfbdev-fbtest-pstore-stockdtbpack-entry12-watchdog/boot-noefi-pmosdtb-watchdog-180s.img
sha256: d5d71d1b23d682c3061cb8158a157739602150a518acb60dcd694c40a2febbca
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
test: mainline 6.17 with PSTORE/RAMOOPS built in plus DRM-console payload
image: /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-224100-mainline617-pstorebuilt-drmconsole-stockdtbpack-entry12-watchdog/boot-noefi-pmosdtb-watchdog-420s.img
sha256: 50b09d45c650ac6ba7234a53dbcdd064d425d7df8c524133652b36696148fb40
kernel sha256: 48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83
config sha256: af45c52e0176343e6696dbed5f6a65fd51af639441598ac9d010318b813ee185
run log: /home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-224052/run.log
result: timeout after 720s, no fastboot/recovery ADB/pmOS SSH/USB device
manual fastboot return observed: 2026-07-10 00:17:58 CEST
restore: 215005 DRM-console image flashed by rescue watcher, then system reboot
pmOS SSH returned: 2026-07-10 00:21:14 CEST, boot_id 5a6cd93e-28c5-47dc-84fe-119534c8b2e1
post-recovery boot_b: 215005 DRM-console image verified
post-recovery pstore: mounted, empty
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

No detached rescue watcher is currently running after the 00:17:58 restoration.
Future risky tests should start their own companion watcher.

Latest watcher action:

```text
watcher log: /home/srobin/dev/hotdog/logs/manual-rescue-watchers/rescue-drmconsole-215005-current.log
fastboot visible: 2026-07-10 00:17:58 CEST
restored boot_b: /home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-215005-lineage414-drmconsole-initramfs-rootwatchdog-v2/boot-noefi-pmosdtb-watchdog-300s.img
reboot system: OK
post-recovery boot_b prefix sha256: 1075757fe6c7a582b94c4a9f837cd71b830d36da8e29c60acba85c49e6c57019
```

## Last Mainline Test

Tested image:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-224100-mainline617-pstorebuilt-drmconsole-stockdtbpack-entry12-watchdog/boot-noefi-pmosdtb-watchdog-420s.img
sha256: 50b09d45c650ac6ba7234a53dbcdd064d425d7df8c524133652b36696148fb40
kernel sha256: 48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83
dtb pack sha256: b8ea3d9f87a290c0dc2d94d952442d249c11edaee141a29bc219317f08164bdf
initramfs: watchdog plus DRM-console helper
kernel config: CONFIG_PSTORE=y, CONFIG_PSTORE_RAM=y, CONFIG_PSTORE_CONSOLE=y
```

Run log:

```text
/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-224052/run.log
```

Result:

```text
flash boot_b from pmOS SSH: OK
boot_b verification: OK
reboot observed: USB ping dropped
boot result after 720s: timeout
fastboot/recovery ADB/pmOS SSH: none
host lsusb during timeout: no phone device
manual fastboot recovery later: 2026-07-10 00:17:58 CEST
post-recovery pstore: empty
```

Interpretation:

```text
The bootloader accepted the image well enough not to immediately return to
fastboot, but the kernel did not reach a recoverable USB path. Adding the
DRM-console payload and rebuilding mainline with built-in pstore/ramoops did
not produce visible text, a pstore record, or a 420s watchdog return path. The
hang is probably before the injected initramfs helper starts, before pstore can
record, or before mainline can create `/dev/dri/card0`.
```

## Next Useful Work

1. Keep the downstream 4.14 DRM-console image as the visible baseline for fast
   recovery and phone-side inspection.
2. Treat the mainline timeout as pre-initramfs/pre-pstore or pre-DRM until
   there is evidence that `/init` starts.
3. Make the helper rebuildable on a fresh host instead of relying on the local
   `build/hotdog-drm-console-aarch64` binary pulled from the phone.
4. For mainline, stop treating USB gadget alone as the first milestone. The
   next useful signal is kernel-entry evidence, a bootloader-visible return
   reason, or initramfs reachability through a channel earlier than USB gadget.
5. Do not retest the exact `192100`, `220500`, or `224100` mainline 6.17 images
   without a new kernel/DTB hypothesis.

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
```
