# Mainline 6.16 pmaports image

> This record captures the original `r3` package-to-device milestone. The
> 2026-08-04 [`r4` touchscreen run](2026-08-04-mainline616-touchscreen.md)
> preserves this boot path and adds hardware-validated S6SY761 multitouch.

Date: 2026-08-03

## Result

The `linux-oneplus-hotdog-mainline616` aport now rebuilds the hardware-proven
V43 kernel contract from pinned public source, and the normal postmarketOS
device flow assembles it into a complete split installation. The generated
artifacts contain:

- Linux `6.16.0-sm8150`, built with LLVM and installed through the current
  `/usr/lib/modules` layout;
- a source-built `sm8150-oneplus-hotdog.dtb`;
- a normal postmarketOS initramfs;
- an Android boot image with header version 2;
- separate `pmOS_boot` and `pmOS_root` filesystem images;
- OpenRC, SSH, NetworkManager, the Qualcomm modem support services, and the
  packaged OnePlus firmware set.

This closes the package-to-hardware boundary. The exact output recorded below
was validated offline, wrapped reproducibly with the phone's partition-sized
AVB footer, written with complete device readback verification, and direct-
booted on the physical HD1913. It reached the matching read-write postmarketOS
rootfs, USB networking, and SSH without executing the downstream kernel or
using kexec.

## Build environment

The full build used pmbootstrap `3.10.1` and pmaports commit:

```text
918a1f4e4dd1ebcf0e4df226dbadc210a857fe9c
```

The kernel source is pinned to ClearStaff commit:

```text
403b56c33e2ccdda25d90378970a5e5b928dee19
```

The complete installation was generated with the standard device-package
flow. The invocation below is sanitized to omit the locally supplied login
credential:

```sh
HOTDOG_PMAPORTS_SM8150="$PWD/src/postmarketos/pmaports-current" \
HOTDOG_PMBOOTSTRAP_WORK="$PWD/pmbootstrap-work-current" \
./scripts/pmbootstrap-hotdog.sh -y -j 32 --details-to-stdout \
  install --split --no-sparse --no-firewall
```

The password was supplied locally and is intentionally omitted. The disabled
firewall is a laboratory-image setting, not a proposed upstream default.

## Package identities

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r3.apk` | 25,534,706 bytes | `513ff02bc7f501b72061f50cbe44aa13e3ba9311ea414228a0792103aecebcee` |
| `device-oneplus-hotdog-3-r3.apk` | 1,981 bytes | `38bce36e537462bdc3c496152fe53df50e2929a5a91bbc2b9906363c7c9968b4` |
| `device-oneplus-hotdog-kernel-mainline-3-r3.apk` | 2,075 bytes | `3cd85b2e3f18c401510881202d9a7764fe386f85a627b55aa962d92edde1687f` |
| `device-oneplus-hotdog-nonfree-firmware-3-r3.apk` | 1,430 bytes | `1af38ef032b9ba19c7c4cf5ee2b6a4addf0097698be2e9f86cc5e3a92bd89cc3` |

The kernel package's integrated validator reported:

```text
hotdog mainline 6.16 build contract: PASS
```

The embedded kernel identity is deterministic:

```text
Linux version 6.16.0-sm8150 (postmarketOS@pmaports) (Alpine clang version 22.1.8, LLD 22.1.8) #4-oneplus-hotdog-mainline616 SMP PREEMPT 2025-08-22 17:25:08
```

## Installation identities

| Output | Size | SHA256 |
|---|---:|---|
| Kernel `Image` | 27,572,232 bytes | `86775a0b6b6db7ff0885c94cccb6b6521f2f517127154e8c9f1d9938b884d3f4` |
| `sm8150-oneplus-hotdog.dtb` | 138,194 bytes | `d043e06a4fa685ef4527872bddc0788f82ff55ef4ad98358ec3b111da9b4379f` |
| initramfs | 9,478,673 bytes | `347365a8e008a4f1d8b6788a6e933945a1eb940faa6af53b4057ba92d938c0bd` |
| raw Android `boot.img` | 37,199,872 bytes | `7a914b47b5cc993c0d3cc7a3d5430501f1d4da87be60b0acbf2621c392b8bfba` |
| `pmOS_boot` filesystem image | 536,870,912 bytes | `ee45f02251319a5a09da79a6063a81cf532aff614d11224bd13e20b2a2aece2a` |
| `pmOS_root` filesystem image | 980,418,560 bytes | `fccb0e9d8982afef885d912352f07763c7fc40ba054a0d949995820eb03a3a14` |

The filesystem labels and UUIDs are:

| Filesystem | Label | UUID |
|---|---|---|
| boot | `pmOS_boot` | `d8b06efa-af97-4d07-ba75-95ca38704af1` |
| root | `pmOS_root` | `c0334266-a480-4c64-9faf-dd0c57a1e404` |

The UUIDs in the Android boot command line match `/etc/fstab` in the generated
root image.

## Boot-image contract

Offline unpacking confirms:

- Android boot header version 2;
- 4096-byte pages;
- kernel offset `0x00008000`;
- ramdisk offset `0x01000000`;
- DTB offset `0x01f00000`;
- kernel, ramdisk, and DTB payloads byte-identical to their source files;
- a 397-byte command line, below the measured 511-byte HD1913 ABL limit;
- `iommu.passthrough=0`, required by the hardware-proven translated DWC3 Apps
  SMMU path;
- `fbcon=font:TER16x32` for the readable 90x97 console;
- no `quiet`, `splash`, or Plymouth command-line options.

The generated initramfs contains the standard postmarketOS nested-partition
discovery and switch-root path, configfs NCM/RNDIS fallback setup, udev, ext4
tools, the mainline module tree, and the required early Adreno firmware. The
root image enables `sshd`, NetworkManager, `tqftpserv`, and `pd-mapper` through
normal OpenRC runlevels.

## Partition-sized AVB image

`scripts/wrap-pmaports-boot-avb.sh` validates the generated Android image
before copying it into the hardware-proven OnePlus boot-partition envelope. It
checks the header version, page and load addresses, empty header-v2
`extra_cmdline`, command-line length and required tokens, and the raw image's
fit before adding a deterministic AVB hash footer.

| Property | Value |
|---|---|
| Raw image size | 37,199,872 bytes |
| Raw image SHA256 | `7a914b47b5cc993c0d3cc7a3d5430501f1d4da87be60b0acbf2621c392b8bfba` |
| AVB image size | 100,663,296 bytes |
| AVB image SHA256 | `df87c5442859caeaeba08bfe2abb4f7b723437124b9764d9bf8d63b8be7a4fca` |
| AVB version | 1.0 |
| Algorithm | `NONE` |
| Partition name | `boot` |
| Command-line size | 397 bytes |

The AVB size, version, algorithm, and partition descriptor match the V43
hardware-proven envelope. `avbtool verify_image` validates both the footer and
the SHA-256 descriptor. The AVB operation leaves the complete 37,199,872-byte
raw-image prefix unchanged. Two clean output directories produced
byte-identical AVB images, establishing deterministic wrapping.

## Hardware validation

The split filesystem outputs were assembled by
`scripts/assemble-pmaports-subpartition-image.sh` into a deterministic
4096-byte-sector GPT containing exactly `pmOS_boot` and `pmOS_root`.

| Staged output | Size | SHA256 |
|---|---:|---|
| Combined nested-GPT image | 1,534,066,688 bytes | `7bd3ab46012a9f73a5d2468a8a8d058fa7e3e527e1b9ed90f9392c4274db107c` |

The combined image was written to the start of the dedicated test phone's
`userdata` partition and read back in full with the same hash. Attaching that
partition with 4096-byte logical sectors exposed the expected two partitions,
their exact source sizes, and UUIDs. This placement preserves the V43 rootfs in
`super` as a manual recovery environment; it is a controlled laboratory
deployment, not the final installation method proposed for pmaports.

The 100,663,296-byte AVB image was then written to `boot_b`. A full partition
readback on the phone produced SHA256
`df87c5442859caeaeba08bfe2abb4f7b723437124b9764d9bf8d63b8be7a4fca`,
identical to the host artifact. One normal reboot produced this fresh identity:

```text
Boot ID: 03d2e4e7-46df-4589-a3ee-d61b06659e25
Linux hotdog 6.16.0-sm8150 #4-oneplus-hotdog-mainline616 SMP PREEMPT 2025-08-22 17:25:08 aarch64 Linux
```

USB ping returned during startup and SSH verified the candidate 18 seconds
after the reboot dispatch. The lack of the V43 `+` suffix, the package-specific
build tag, both new UUIDs in `/proc/cmdline`, and the exact `boot_b` readback
exclude the recovery baseline.

The standard postmarketOS initramfs found the matching nested GPT on
`/dev/sda22`, repaired the backup GPT location, expanded the root partition and
filesystem to the available `userdata` capacity, and mounted:

| Mount | Device | Filesystem | UUID |
|---|---|---|---|
| `/boot` | `/dev/loop0p1` | ext2, read-write | `d8b06efa-af97-4d07-ba75-95ca38704af1` |
| `/` | `/dev/loop0p2` | ext4, read-write | `c0334266-a480-4c64-9faf-dd0c57a1e404` |

The expanded root filesystem is 231,837,532,160 bytes. OpenRC started udev,
DBus, NetworkManager, `sshd`, `pd-mapper`, and `tqftpserv`. The host retained
`172.16.42.2/24`, received three successful pings from `172.16.42.1`, and kept
stable SSH access. Native MSM DRM initialized, registered `fb0`, and displayed
the kernel plus initramfs console on the panel.

This exact boot also provides the initial hardware-support baseline. UFS,
display/fbcon, the Power key, USB networking, and SSH work. No touchscreen,
WLAN/rfkill device, ALSA sound card, or battery power-supply class was exposed;
the kernel also reports that no GPU device was found. These are enablement
targets rather than failures of the validated boot path.

## Historical strict-build milestone

The first strict build, `6.16.0-r0`, established that all 15 public patches
apply and that the Image, modules, and source-generated DTB compile together.
Its APK SHA256 was
`ee5c55ddde8c9a385d1b11af799df2a373110dabc4441614b33b8712877408ce`.
Revision r3 adds current usrmerge module placement and deterministic kernel
build metadata; the r0 identity must not be used for the hardware candidate.

## Remaining work

The exact package-built image has passed its first direct hardware boot. Clean
reboot-to-bootloader and reboot-to-recovery behavior still need validation.
The temporary `userdata` deployment must be replaced by a documented standard
installation path, and the device-specific reference package must migrate into
the shared SM8150 kernel package. Temporary UFS DMA32, UFS/QUP SMMU bypasses,
ICE removal, incomplete peripheral descriptions, and debug command-line options
remain bring-up debt rather than an upstream submission design.
