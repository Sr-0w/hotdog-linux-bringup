# Package-complete runtime checkpoint

Date: 2026-08-25

The running hardware checkpoint had accumulated kernel fixes plus several
unowned sensor/proximity files. Packaging only the final UFS ICE change would
have made the next image regress touch/radio lifecycle, alert slider, sensors
and ultrasonic proximity. This checkpoint closes that reproducibility gap.

## Kernel package

`linux-oneplus-hotdog-mainline616 6.16.0-r181` adds one net patch from the last
public package checkpoint to the exact hardware-tested kernel tree. The full
patch stack applies cleanly to the pinned public source and completes `Image
modules dtbs`. The package validator passes on the resulting artifacts.

| Artifact | SHA-256 |
|---|---|
| Kernel APK | `2dc1fb68d6a9b2b09146a24266088bc9ffca7c3a236f2a8c72f607507e343ba8` |
| Image inside boot/APK | `17782d2cb35945be8cb23059b78f0f2156e7926455faf18b9c02bb16a18c34fd` |
| Hotdog DTB | `2259af449ee980167c80cca0c0e6b3af9f9f5a601226158a8e9e9b127bcb62d6` |
| packaged `q6elliptic.ko` | `7aa5d725f1b84b77de26d4d9a850be438eda05749a8666c5c0b4214c2d718034` |
| packaged `q6hostless.ko` | `e1dc3f4dff73f507af25cac8965d46910a21a6159c9748845da3a3ea37b89cce` |

## Userspace ownership

`device-oneplus-hotdog-sensors 3-r32` now owns the SLPI gate, SSC client,
OxygenOS board-identity provisioner, factory sensor-calibration importer,
Elliptic provisioner, udev rule, bounded smoke test and on-demand arming daemon.
Its OpenRC post-install enables `hotdog-sensor-gate` and
`hotdog-proximity-arm`, and removes the disproved passive-ALS proximity daemon.

`iio-sensor-proxy 9999-r9` is now tracked as a public aport snapshot with the
SSC patches actually installed on the phone. Both packages build cleanly.

| Artifact | SHA-256 |
|---|---|
| sensor integration APK | `6c325a9a901f879f18fcb5fe6ec3c70618c1361a9ba5bbf73ffc6b8cec6f447e` |
| iio-sensor-proxy APK | `666e49e0b672f1bda4f292c431c82dcd0a5a19e22396558dd51cb2be816af3cb` |

The 448-byte Elliptic calibration remains per-device and outside Git. The
reference phone's already-active value was copied into a dedicated `persist`
path and read back byte-for-byte. The public provisioner validates size and
non-zero content before installing it; it never substitutes another device's
value.

## Fresh image

A new rootfs was composed with explicit, versioned packages rather than
mutable package recommendations. The image contains the two new kernel modules,
all sensor runtime files and both default-runlevel services. No former manual
sensor/SSC/Hexagon/proximity script exists under `/root`.

| Artifact | SHA-256 |
|---|---|
| AVB boot image | `f25d776351b1a11d74f1523e2b9ee15cd4326100fa32c3bf9951e8f35edefab7` |
| pmOS_boot filesystem | `619085cdea8fe3f78963ff93245575547b14baf741467dce8f1c0645b6314ac7` |
| pmOS_root filesystem | `024ee81e01538ce931bf23899d0cfbd4049005aeecaf83c0a26c5a4178b56998` |
| assembled GPT image | `2c7a65b179ccbadad27db924e255723d2c6481ec170eeef06be0513c53c12c6b` |

Both filesystems pass `e2fsck -fn`. AVB verification passes, boot and APK
kernel/DTB payloads are byte-identical, both GPT partitions passed complete
readback hashing, and `sgdisk --verify` passes. This is offline image evidence;
the exact package-complete image still needs one guarded hardware boot.
