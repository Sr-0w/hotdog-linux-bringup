# OnePlus 7T Pro postmarketOS v0.1.0-alpha.5

`v0.1.0-alpha.5` is a fresh package-complete rebuild for the OnePlus 7T Pro
HD1913 (`hotdog`). It supersedes Alpha 4. Do not mix its boot, DTBO or rootfs
with another release.

## What changed

- Kernel `linux-oneplus-hotdog-mainline616 6.16.0-r181` carries the complete
  net delta of the hardware-tested runtime: touch/camera/radio lifecycle fixes,
  generic alert slider, QDSP6 hostless/Elliptic proximity, UFS ICE and the
  PM8150 plus IMEM reboot reasons.
- Device package `device-oneplus-hotdog 3-r32` owns the SLPI gate, SSC probe,
  factory-calibration importer, proximity udev rule, smoke test and on-demand
  ultrasound arming service. These are no longer manual `/root` files.
- `iio-sensor-proxy 9999-r9` contains the SSC source support, claim-race fix and
  safe shutdown fix that are present on the validated development phone.
- The fresh rootfs contains `q6elliptic.ko`, `q6hostless.ko`, both OpenRC
  services and their package ownership. The disproved passive-ALS proximity
  daemon is removed from the runlevel.
- The filtered DTBO is byte-identical to Alpha 4 because this checkpoint has no
  DTBO delta; kernel and Hotdog DTS changes are in the new source-built DTB.

## Calibration contract

The Elliptic calibration is a 448-byte per-device value and is not published in
Git or copied from the development handset into the release. The packaged
provisioner restores it from `persist` and rejects missing, wrong-size or
all-zero data. The reference HD1913 has its existing calibration stored there
with an exact readback. Another handset must provision its own matching value;
without it the proximity path fails closed rather than using another phone's
calibration.

## Validation

The exact kernel patch stack applies to the public source commit and completes
`Image modules dtbs`. Its final build contract verifies ICE, both reboot-mode
descriptions, alert-slider states, Elliptic/hostless DT links and modules.

The rootfs was composed from scratch. Both filesystems pass `e2fsck -fn`; the
boot image passes AVB verification; the unpacked kernel/DTB match the kernel APK;
and the deterministic 4096-byte-sector GPT passed full partition readback plus
`sgdisk --verify`.

The underlying kernel state has hardware-validated UFS ICE, bootloader and
recovery selection, sensor streaming, auto-rotation, alert slider and Elliptic
proximity. The exact complete Alpha 5 image set has not yet been flashed or
booted as a unit.

## Important limitations

- No SIM is currently inserted. Registration, LTE data, SMS, calls, call audio
  and call-time proximity blanking are not validated.
- Bluetooth controller initialization and suspend/unload lifecycle are broken
  in the current checkpoint.
- The existing recovery is Android/Lineage userdebug; no native postmarketOS
  recovery is supplied.
- ICE operation does not prove that the current rootfs is encrypted.
- Display/DSI stability, DisplayPort audio, remaining audio routes, production
  camera processing, fingerprint and Warp charging remain incomplete.

Read the attached `INSTALL.md`, verify `SHA256SUMS`, and keep a complete
model-correct recovery path before flashing.
