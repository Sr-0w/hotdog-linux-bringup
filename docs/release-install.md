# Release installation and versioning

## Scope

Release images are experimental postmarketOS builds for the **OnePlus 7T Pro
HD1913** with the `hotdog` codename and an **unlocked bootloader**. Do not use
them on another OnePlus model solely because it looks similar. A wrong boot
image or a failed test kernel can require fastboot or recovery to regain access.

The project publishes a boot image, a filtered DTBO image and a rootfs image as
one atomic release set. The boot command line contains the UUIDs of the
`pmOS_boot` and `pmOS_root` filesystems inside the rootfs image. Never mix any
of these three images with an asset from another release.

## Version policy

Public releases use SemVer pre-release tags:

`vMAJOR.MINOR.PATCH-alpha.N` and `vMAJOR.MINOR.PATCH-beta.N`

- `alpha` means a hardware-development image that can have serious missing
  functions or recovery requirements.
- `beta` is reserved for a substantially broader, repeatably-tested daily-use
  experience; it is not a promise of postmarketOS upstream support.
- Increment `N` for a rebuilt or corrected release within the same public
  milestone.
- Increment `PATCH` for a compatible image-level fix. Increment `MINOR` when a
  meaningful hardware milestone changes the expected usable surface.
- Internal experiment identifiers such as `R108`, `D39`, or `V43` remain
  evidence references. They are not public release versions.

The first public image set is planned as `v0.1.0-alpha.1`. Every release must
provide a source tag, `SHA256SUMS`, a manifest, an AVB-verified boot image, and
a rootfs image whose filesystem UUIDs match that boot image. A release is
replaced, not silently edited, when any asset changes.

## Before flashing

1. Read the matching release notes and the current [support status](status.md).
2. Back up any data that matters. Flashing `super` replaces the Android system
   layout used by this experiment. Do not expect Android to remain bootable.
3. Keep an official HD1913 OxygenOS or Lineage recovery path available. This
   project does not distribute proprietary factory images.
4. Install Android Platform Tools (`fastboot`), `zstd`, `sha256sum`, and keep
   at least 20 GiB of free host storage for the expanded rootfs image.
5. Enter bootloader fastboot and verify the target. The OnePlus bootloader
   reports the platform product `msmnile`, not the Linux codename `hotdog`.
   Stop unless the physical phone is an HD1913, `product` is `msmnile`, the
   bootloader is unlocked and `is-userspace` is `no`.

```bash
fastboot devices
fastboot getvar product
fastboot getvar unlocked
fastboot getvar is-userspace
```

Do not use `fastboot getvar all` in a public log: it prints the device serial.

## Back up slot B before changing it

This release intentionally uses slot B and leaves slot A untouched. Before
flashing, make complete local backups of the current `boot_b` and `dtbo_b` and
record their hashes. Recent Android Platform Tools can read a physical
partition with `fastboot fetch`:

```bash
mkdir hotdog-slot-b-backup
fastboot fetch boot_b hotdog-slot-b-backup/boot_b.img
fastboot fetch dtbo_b hotdog-slot-b-backup/dtbo_b.img
sha256sum hotdog-slot-b-backup/boot_b.img \
  hotdog-slot-b-backup/dtbo_b.img \
  > hotdog-slot-b-backup/SHA256SUMS
test "$(stat -c %s hotdog-slot-b-backup/boot_b.img)" -eq 100663296
test "$(stat -c %s hotdog-slot-b-backup/dtbo_b.img)" -eq 25165824
```

On macOS, use `shasum -a 256` and `stat -f %z` for the equivalent checks. If
the installed `fastboot` does not support `fetch`, stop and back up both
partitions from a trusted recovery shell before continuing. Do not flash first
and plan the rollback later.

## Verify and expand the download

Download every asset attached to one release tag and verify it before
extracting or flashing:

```bash
sha256sum -c SHA256SUMS
```

For split rootfs assets, reconstruct the archive in numeric order, verify it,
then expand it. The expanded file is a raw 4096-byte-sector GPT image containing
`pmOS_boot` and `pmOS_root`; it is not an Android sparse image.

```bash
cat oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img.zst.part* \
  > oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img.zst
zstd -d --keep oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img.zst
# Compare this digest with the "Rootfs raw SHA-256" in MANIFEST.md.
sha256sum oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img
```

## Flash the matching set

The rootfs is written to physical `super`. The filtered DTBO and mainline boot
image are written to `dtbo_b` and `boot_b`, leaving slot A untouched as an
additional recovery option. Flashing `super` replaces the Android system
layout and is destructive. Confirm that the backups above are readable before
continuing.

Use userspace fastboot (`fastbootd`) for `super`. The HD1913 bootloader accepted
the first large sparse segment during release validation but stopped responding
on the next transfer. Fastbootd completed the same image as 30 bounded segments.

```bash
# Start in bootloader fastboot, then enter the recovery-provided fastbootd.
fastboot reboot fastboot
fastboot getvar is-userspace  # must report: yes

# Keep sparse transfers small enough for the tested HD1913 USB path.
fastboot -S 128M flash super \
  oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img
fastboot reboot bootloader
fastboot getvar is-userspace  # must report: no
fastboot getvar product       # must report: msmnile
fastboot flash dtbo_b oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-dtbo.img
fastboot flash boot_b oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-boot.img
fastboot set_active b
fastboot reboot
```

If `fastboot reboot fastboot` cannot start fastbootd, the active slot does not
contain a compatible recovery. Restore or select a known-good HD1913 recovery
slot before continuing. Do not substitute a direct bootloader `super` flash.
In this project's slot layout, `boot_a` is deliberately preserved for that
recovery path and postmarketOS is installed to `boot_b`.

The first boot can take longer than normal while the root partition is checked
and expanded. A healthy boot reaches Plasma Mobile and exposes USB networking
at `172.16.42.1`.

## First login and recovery

The Alpha image initialises a public test account. Change both values before
connecting to an untrusted network.

| Item | Value |
|---|---|
| User | `user` |
| Password | `147147` |
| Initial Plasma PIN | `147147` |
| USB network address | `172.16.42.1` |

With a host configured at `172.16.42.2/24`, SSH is available as:

```bash
ssh user@172.16.42.1
```

Normal software reboot is validated. Reboot-to-bootloader/recovery from the
running Alpha is not; enter those modes with the physical key sequence when
maintenance is required.

If the phone enumerates as Qualcomm `05c6:900e` or `05c6:9008`, inspect it
read-only only. Never issue a protocol reset, reboot or flash command in that
state. Disconnect it and use the physical HD1913 key sequence to return to
bootloader fastboot, then confirm `fastboot devices` before writing anything.
A failed Alpha boot can be recovered by restoring both saved slot-B images:

```bash
fastboot flash dtbo_b hotdog-slot-b-backup/dtbo_b.img
fastboot flash boot_b hotdog-slot-b-backup/boot_b.img
fastboot set_active b
```

Alternatively select an intact slot A or restore official software for the
exact model. Do not restore only one half of the boot/DTBO pair, and do not
flash a boot or DTBO image from another release against this rootfs.

## Current Alpha limitations

This is not a daily-driver image. Suspend/resume, DisplayPort audio, UFS ICE,
telephony, front and ultra-wide cameras, sensors, NFC, fingerprint, and several
audio paths remain incomplete or untested. Main and telephoto capture work, but
autofocus and production colour calibration remain incomplete. Refer to
[status.md](status.md) for the evidence-backed matrix.
