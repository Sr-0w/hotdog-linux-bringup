# Current boot cycle

Date: 2026-07-09 20:38 CEST

## Current status

The last known-good phone state was pmOS over USB SSH on the downstream
Lineage/OpenELA 4.14.357 kernel rebuilt with devtmpfs and DRM fbdev diagnostic
options.

Known-good boot image:

```text
/home/srobin/dev/hotdog/images/pmos-experiments/2026-07-09-195300-lineage414-devtmpfs-drmfbdev-fbtest-pstore-stockdtbpack-entry12-watchdog/boot-noefi-pmosdtb-watchdog-180s.img
sha256: d5d71d1b23d682c3061cb8158a157739602150a518acb60dcd694c40a2febbca
kernel sha256: dfac91230b3b2783fbd79408a5cd62f47bc2a86a4586347d814c5144d76d84d9
dtb pack sha256: b8ea3d9f87a290c0dc2d94d952442d249c11edaee141a29bc219317f08164bdf
```

Validated on that image:

```text
pmOS SSH: user@172.16.42.1
final stable boot_id: 0d9701d8-02e5-48b3-9056-2ee49fca91d5
/dev/dri/card0 and /dev/dri/renderD128 exist
DRM driver: MSM Snapdragon DRM / msm_drm
DSI-1: connected, 1440x3120 mode available
Plymouth local.d hook keeps DSI-1 enabled after userspace boot
```

Phone-side runtime hook:

```text
/etc/local.d/hotdog-plymouth.start
```

The hook waits for `/dev/dri/card0` and connected `DSI-1`, then starts
`plymouthd --no-daemon --mode=boot --tty=/dev/tty0 --graphical-boot`.

## Current phone visibility

The phone is currently not visible from the host after the mainline 6.17 test:

```text
adb devices -l      -> empty
fastboot devices -l -> empty
lsusb               -> no OnePlus/Google/Qualcomm phone device
pmOS SSH            -> not reachable
```

This means there is no host-side software recovery path until the device
reappears in fastboot or recovery ADB.

## Active rescue watcher

A detached rescue watcher is armed. If the phone appears in fastboot or recovery
ADB, it restores the known-good boot image above to `boot_b`, sets slot `b`
active, and reboots system.

```text
pid: 4166591
pid file: /home/srobin/dev/hotdog/logs/manual-rescue-watchers/rescue-stable-drm-current.pid
log link: /home/srobin/dev/hotdog/logs/manual-rescue-watchers/rescue-stable-drm-current.log
restore action: system reboot
```

## Last test

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
host lsusb: no phone device
```

Interpretation:

```text
The bootloader accepted the image well enough not to immediately return to
fastboot, but the kernel did not reach a recoverable USB path. Because the
420s initramfs watchdog did not force a visible reboot, the hang is probably
before the injected initramfs watchdog starts, or early enough that the rescue
path cannot run.
```

## Next useful work

1. When the phone is manually returned to fastboot or recovery ADB, let the
   active watcher restore the stable downstream pmOS boot image.
2. After stable SSH returns, collect any available pstore/ramoops state.
3. Keep the downstream 4.14 DRM/Plymouth image as the baseline for fast
   recovery and for phone-side inspection.
4. For mainline, stop treating USB gadget alone as the first milestone. The
   current blocker is earlier: kernel entry, DTB compatibility, early console,
   initramfs reachability, or a very early panic/hang.

## Reports

High-signal notes:

```text
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/66-devtmpfs-drm-plymouth-display-20260709.txt
/home/srobin/dev/hotdog/reports/lineage414-openela-diff-20260709-140656/67-mainline617-timeout-20260709.txt
```
