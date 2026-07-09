# Current boot cycle

Date: 2026-07-09 21:12 CEST

## Current Status

The phone has been recovered to the known-good downstream pmOS boot after the
mainline 6.17 timeout.

```text
pmOS SSH: user@172.16.42.1 reachable
boot_id: f43b6b3a-ee33-418b-865b-880b024cd770
kernel: Linux hotdog 4.14.357-openela-perf #2-postmarketOS
DSI-1: enabled
visible test: modetest SMPTE pattern on DSI-1
USB network: usb0 on the phone, 172.16.42.1/16
```

Known-good boot image:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-195300-lineage414-devtmpfs-drmfbdev-fbtest-pstore-stockdtbpack-entry12-watchdog/boot-noefi-pmosdtb-watchdog-180s.img
sha256: d5d71d1b23d682c3061cb8158a157739602150a518acb60dcd694c40a2febbca
kernel sha256: dfac91230b3b2783fbd79408a5cd62f47bc2a86a4586347d814c5144d76d84d9
dtb pack sha256: b8ea3d9f87a290c0dc2d94d952442d249c11edaee141a29bc219317f08164bdf
```

Recovery path used:

```text
/home/srobin/dev/hotdog/logs/rescue-boot-b-when-visible-2026-07-09-203849/run.log
```

Result:

```text
fastboot appeared: 2026-07-09 20:51:48 CEST
restored boot_b: OK
set active slot b: OK
reboot system: OK
pmOS SSH returned: 2026-07-09 20:55:06 CEST
post-recovery collection: /home/srobin/dev/hotdog/logs/pmos-usb-ssh-2026-07-09-205444
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
visible proof: modetest -s 28@136:#0 -F smpte
```

The phone was reported black even though pmOS SSH was reachable. Installing
`libdrm-tests` and running a held `modetest` pattern proved that the panel,
KMS scanout, and backlight work on the downstream boot. The black screen was
therefore a userspace output problem, not evidence that the stable pmOS boot or
the panel path had failed.

Helper for reproducing the known-good visual pattern:

```text
/home/srobin/dev/hotdog/scripts/show-stable-drm-pattern.sh start
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
mainline 6.17 timeout:

```text
pstore on /sys/fs/pstore type pstore (rw,nosuid,nodev,noexec,relatime)
/sys/fs/pstore: total 0
```

Implication: the failed mainline boot did not leave a readable ramoops/pstore
record. It likely hung without panic, before the pstore backend could write, or
before the injected initramfs watchdog could run.

## Active Rescue Watcher

A detached rescue watcher is armed again. If the phone appears in fastboot or
recovery ADB, it restores the known-good boot image above to `boot_b`, sets slot
`b` active, and reboots system.

```text
pid: 62915
pid file: /home/srobin/dev/hotdog/logs/manual-rescue-watchers/rescue-stable-drm-current.pid
log link: /home/srobin/dev/hotdog/logs/manual-rescue-watchers/rescue-stable-drm-current.log
restore action: system reboot
starter: /home/srobin/dev/hotdog/scripts/start-stable-rescue-watcher.sh
```

## Last Mainline Test

Tested image:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-192100-mainline617-fbtest-directshell-stockdtbpack-entry12-simplefb-rootwatchdog/boot-noefi-pmosdtb-watchdog-420s.img
sha256: 6164e247e934a199700dac58372d964096977159d011699ea7510e0baa9cac59
kernel sha256: 84f33a57aa1f32bcf938d7e9f85e0f3acc2dbf159c8aaed8534e2f13a6fc4004
dtb pack sha256: b8ea3d9f87a290c0dc2d94d952442d249c11edaee141a29bc219317f08164bdf
initramfs sha256: 3c7b5d87041a3a5b62246ede6ff34ec22ad7a2dbdf431f34815ef7b2b0ae5227
```

Run log:

```text
/home/srobin/dev/hotdog/logs/test-boot-b-image-2026-07-09-202324/run.log
```

Result:

```text
flash boot_b from pmOS SSH: OK
boot_b verification: OK
reboot observed: USB ping dropped
boot result after 720s: timeout
fastboot/recovery ADB/pmOS SSH: none
host lsusb during timeout: no phone device
```

Interpretation:

```text
The bootloader accepted the image well enough not to immediately return to
fastboot, but the kernel did not reach a recoverable USB path. Because the
420s initramfs watchdog did not force a visible reboot and pstore stayed empty,
the hang is probably before the injected initramfs watchdog starts, or early
enough that the rescue path cannot run.
```

## Next Useful Work

1. Keep the downstream 4.14 DRM/Plymouth image as the baseline for fast recovery
   and for phone-side inspection.
2. Add a true DRM visual diagnostic to the boot-image builder. The current
   `--fb-test` paints `/dev/fb0`, but the working proof uses KMS on
   `/dev/dri/card0`; a future `--drm-test` should use either a small custom DRM
   dumb-buffer helper or a controlled `modetest` payload.
3. Revalidate one low-risk downstream 4.14 boot with the same DTB
   instrumentation before changing the mainline path again.
4. For mainline, stop treating USB gadget alone as the first milestone. The
   current blocker is earlier: kernel entry, DTB compatibility, early console,
   initramfs reachability, or a very early panic/hang.
5. Do not retest the exact `192100` mainline 6.17 image. If mainline is retried,
   keep the 6.17 kernel but reduce the ramdisk candidate to watchdog/pstore
   only before changing kernel entry code.

Prepared minimal mainline candidate for later, not yet tested:

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
```
