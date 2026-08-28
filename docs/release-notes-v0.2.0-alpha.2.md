# OnePlus 7T Pro postmarketOS v0.2.0-alpha.2

`v0.2.0-alpha.2` supersedes Alpha 1 and completes its installation contract by
shipping the top-level vbmeta state used by LineageOS on Hotdog.

## What changed

- A 64 KiB `vbmeta-disabled` image is now part of the atomic release set.
- The image is derived from the official OxygenOS 12 F.22 top-level vbmeta and
  sets AVB flags `3`: hashtree and verification disabled.
- `INSTALL.md` backs up, flashes and restores `vbmeta_b` together with boot and
  DTBO.
- Boot, DTBO, kernel APK and rootfs remain byte-identical to the hardware-tested
  Alpha 1 assets.

The bootloader must already be unlocked. Modifying the flags invalidates the
stock RSA signature; an unlocked ABL accepts that state, as LineageOS requires
for its own Hotdog boot/DTBO images.

## Why vbmeta is required

The official LineageOS Hotdog configuration supports HD1910, HD1911, HD1913 and
HD1917. Its product identifies as HD1911. The common OnePlus SM8150 BoardConfig
puts `boot`, `dtbo` and `vbmeta` in every A/B OTA and explicitly sets both AVB
disable flags.

The first pmOS releases shipped the Lineage-derived DTBO but omitted vbmeta.
They therefore worked on the reference phone, which had previously run
LineageOS, while a clean OxygenOS HD1911 could retain enforcing stock vbmeta and
return to fastboot before Linux.

## IN/EU comparison

Complete OxygenOS F.22 extraction found 29 of 41 partitions byte-identical.
Every pre-kernel partition is common, including XBL, ABL, boot, DTBO and
top-level vbmeta. The 12 differences are Android regional logical partitions
and their `vbmeta_system` authentication data.

The IN and EU top-level vbmeta inputs are byte-identical, so their flags-3 output
is also identical. There is no distinct HD1911-IN binary set to publish. HD1911
remains unvalidated until an external handset boots the complete Alpha 2 set.
See [the full comparison](evidence/2026-08-28-oxygenos-f22-in-eu-and-lineage.md).

## Artifact identities

| Artifact | SHA-256 |
|---|---|
| Boot image | `7a2b4dd94f4b6bf12a3d3c904493b507786543431252c463b9f8b982b42824b2` |
| Filtered DTBO | `d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd` |
| Verification-disabled vbmeta | `e1d9ee620f4fac7939042396de966bea0b735bf11cea8ccc9b346f4d0fee0d50` |
| Kernel APK | `389931d1a998bed3aaf111429ec26a801c53db2f09ad29e0129be9234eb417c2` |
| Rootfs raw image | `6a824339b106b387d7511a8a3d9f3547f08fc47949c1f8c5c3bd57d6604430cf` |
| Rootfs zstd archive | `d0876ffe555fa01118cf8e08dcef9a02f0c407070051a301859a5e74200baccc` |

## Validation

- The four unchanged binary assets are byte-identical to Alpha 1, whose exact
  package reached Plasma Mobile and SSH and passed a 918-second stability gate.
- The Alpha 2 vbmeta was flashed from the packaged candidate without changing
  boot, DTBO or rootfs; Linux 6.17, writable root and SSH returned.
- Full-partition readback of `vbmeta_b` matched the packaged SHA-256.
- A 31-sample monitor covered 919 seconds with one unchanged boot ID, continuous
  SSH, no fastboot return and no Qualcomm 9008/900e transition.
- A second control converted slot A to a complete HD1911-IN F.22 Android
  userspace baseline, confirmed it bootable, then installed the exact Alpha 2
  payload set. Linux 6.17 and SSH returned in 81 seconds; full
  `boot_a`, `dtbo_a` and `vbmeta_a` readback matched the public release hashes.
  The handset still exposed its physical HD1913 project identity, so this
  excludes IN userspace differences but is not an HD1911 hardware validation.
- A second 31-sample monitor passed for 907 seconds with continuous USB, ping
  and SSH and one unchanged boot ID. Live `super` metadata contained no
  `vendor_dlkm`, the only LineageOS payload image absent from OxygenOS F.22.
- Offline AVB metadata inspection reports flags `3`; package generation rejects
  any other flags or partition size.

## Scope

This remains an experimental HD1913 release and is not a daily-driver claim.
The complete support matrix and remaining telephony, camera, fingerprint,
charging, audio and suspend gaps are documented in [status.md](status.md).

Read the attached `INSTALL.md`, verify `SHA256SUMS`, back up user data and keep a
model-correct recovery path before flashing.
