# Mainline 6.16 pmaports image

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

This closes the package-to-image build boundary. The exact output recorded
below is offline-validated but has not yet been wrapped with the phone's
partition-sized AVB footer or booted on hardware.

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

## Historical strict-build milestone

The first strict build, `6.16.0-r0`, established that all 15 public patches
apply and that the Image, modules, and source-generated DTB compile together.
Its APK SHA256 was
`ee5c55ddde8c9a385d1b11af799df2a373110dabc4441614b33b8712877408ce`.
Revision r3 adds current usrmerge module placement and deterministic kernel
build metadata; the r0 identity must not be used for the hardware candidate.

## Remaining gate

Before writing the phone, the raw pmaports `boot.img` must be copied into the
validated 96 MiB OnePlus boot-partition envelope and receive a verified AVB
hash footer. The exact AVB image then needs a guarded write, readback hash, and
one direct hardware boot. Temporary UFS DMA32, UFS/QUP SMMU bypasses, ICE
removal, the device-specific kernel package, and debug command-line options
remain bring-up debt rather than an upstream submission design.
