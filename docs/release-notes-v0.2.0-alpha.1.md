# OnePlus 7T Pro postmarketOS v0.2.0-alpha.1

`v0.2.0-alpha.1` is the first public release built from the clean SM8150 Linux
6.17 migration for the OnePlus 7T Pro HD1913 (`hotdog`). It supersedes Alpha 5.

## Why this is v0.2.0

This release changes both the kernel line and the installation contract:

- Linux moves from the 6.16 oracle to `linux-oneplus-hotdog-mainline617-clean`
  `6.17.0-r10`;
- the current postmarketOS initramfs discovers the nested GPT through a
  4096-byte-sector loop device;
- the rootfs is flashed to `userdata`, not Android `super`;
- Android `super`, both recovery partitions and slot A boot/DTBO remain intact.

The 6.16 tree remains an immutable hardware oracle. It is not the active public
image after this release.

## Alpha 5 regression fixed

Alpha 5 combined an old initramfs subpartition path with a root image flashed to
physical `super`. On a clean OxygenOS baseline its kernel reached the initramfs,
then blocked while `kpartx` mapped the nested GPT. Extending the GPT alone moved
the failure into stage two but did not make the old path reliable.

The 6.17 stack uses the maintained postmarketOS loop-device implementation and
targets `userdata`. The exact candidate release assets were flashed over a clean
OxygenOS 12 control without touching vbmeta. They reached Plasma Mobile and SSH,
and the phone read back the exact published boot and DTBO hashes.

## Artifact identities

| Artifact | SHA-256 |
|---|---|
| Boot image | `7a2b4dd94f4b6bf12a3d3c904493b507786543431252c463b9f8b982b42824b2` |
| Filtered DTBO | `d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd` |
| Kernel APK | `389931d1a998bed3aaf111429ec26a801c53db2f09ad29e0129be9234eb417c2` |
| Rootfs raw image | `6a824339b106b387d7511a8a3d9f3547f08fc47949c1f8c5c3bd57d6604430cf` |
| Rootfs zstd archive | `d0876ffe555fa01118cf8e08dcef9a02f0c407070051a301859a5e74200baccc` |

The boot image, DTBO, kernel APK and rootfs are one atomic set. Do not mix them
with Alpha 5 or another internal build.

## Validation

- `sha256sum -c` passes for the packaged assets.
- AVB verification passes for boot and DTBO.
- The boot kernel and DTB are byte-identical to the kernel APK payloads.
- The rootfs GPT uses 4096-byte sectors, contains exactly `pmOS_boot` and
  `pmOS_root`, and passes `sgdisk --verify` plus read-only `e2fsck`.
- `/boot/boot.img` inside the rootfs is byte-identical to the release boot image.
- The decompressed release asset was flashed to `userdata`; the release boot and
  DTBO assets were flashed to slot B without changing vbmeta.
- The exact set reached Linux 6.17, writable root, OpenRC, Plasma Mobile, NCM and
  SSH. Boot and DTBO partition readbacks matched the release hashes.
- A 31-sample monitor covered 918 seconds with one unchanged boot ID, continuous
  SSH, no fastboot return and no Qualcomm 9008/900e transition.

## Scope and limitations

This remains an experimental HD1913 release. It is not a daily-driver claim and
does not establish HD1911 support. A separate HD1911 report returns to the
bootloader before the failure reproduced on the reference HD1913, so its
board/DTBO selection remains under investigation.

The hardware limitations in [status.md](status.md) still apply. In particular,
telephony, production camera integration, fingerprint, Warp charging, remaining
audio paths and broad suspend/resume stability are not promoted by this release.

Read the attached `INSTALL.md`, verify `SHA256SUMS`, back up user data and keep a
model-correct recovery path before flashing.
