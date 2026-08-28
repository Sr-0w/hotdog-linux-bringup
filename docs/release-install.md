# Release installation and versioning

## Scope

Release images are experimental postmarketOS builds for the **OnePlus 7T Pro
HD1913** with the `hotdog` codename and an **unlocked bootloader**. Do not use
them on another OnePlus model solely because it looks similar. A wrong boot
image or a failed test kernel can require fastboot or recovery to regain access.

The project publishes a boot image, a filtered DTBO image, a verification-
disabled vbmeta image and a rootfs image as one atomic release set. The boot
command line contains the UUIDs of the
`pmOS_boot` and `pmOS_root` filesystems inside the rootfs image. Never mix any
of these images with an asset from another release.

The vbmeta asset is derived from the byte-identical HD1911-IN and HD1913-EU
OxygenOS 12 F.22 top-level vbmeta and sets AVB flags `3` (hashtree and
verification disabled), matching the LineageOS Hotdog installation contract.
It is intended only for an already-unlocked bootloader.

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

Every release provides a source tag, `SHA256SUMS`, a manifest, an AVB-verified
boot image, a verified filtered DTBO and a rootfs image whose filesystem UUIDs
match that boot image. A release is replaced, not silently edited, when any
asset changes.

## Before flashing

1. Read the matching release notes and the current [support status](status.md).
2. Back up any data that matters. Flashing `userdata` destroys Android user
   data and replaces the whole partition with the nested pmOS disk image.
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

This release intentionally uses slot B and leaves `boot_a`, `dtbo_a`, Android
`super` and both recovery partitions untouched. `userdata` is shared and will
be destroyed, so an Android slot may still reach recovery or initial setup but
cannot retain its user data. Before flashing, use a trusted root recovery to
make complete local backups of `boot_b`, `dtbo_b` and `vbmeta_b`, then record
their hashes.
The Hotdog fastboot implementations tested here do not support `fastboot fetch`.

```bash
mkdir hotdog-slot-b-backup
adb devices                  # must report the trusted recovery as recovery
adb exec-out 'dd if=/dev/block/by-name/boot_b bs=4M' \
  > hotdog-slot-b-backup/boot_b.img
adb exec-out 'dd if=/dev/block/by-name/dtbo_b bs=4M' \
  > hotdog-slot-b-backup/dtbo_b.img
adb exec-out 'dd if=/dev/block/by-name/vbmeta_b bs=4096 count=16' \
  > hotdog-slot-b-backup/vbmeta_b.img
sha256sum hotdog-slot-b-backup/boot_b.img \
  hotdog-slot-b-backup/dtbo_b.img hotdog-slot-b-backup/vbmeta_b.img \
  > hotdog-slot-b-backup/SHA256SUMS
test "$(stat -c %s hotdog-slot-b-backup/boot_b.img)" -eq 100663296
test "$(stat -c %s hotdog-slot-b-backup/dtbo_b.img)" -eq 25165824
test "$(stat -c %s hotdog-slot-b-backup/vbmeta_b.img)" -eq 65536
```

On macOS, use `shasum -a 256` and `stat -f %z` for the equivalent checks. Do not
flash first and plan the rollback later. After verifying the backup, use the
recovery UI or `adb reboot fastboot` to enter fastbootd.

## Verify and expand the download

Download every asset attached to one release tag and verify it before
extracting or flashing:

```bash
sha256sum -c SHA256SUMS
```

On macOS, the equivalent command is `shasum -a 256 -c SHA256SUMS`.
Use `stat -f %z` instead of `stat -c %s` for the two size checks below.

For split rootfs assets, reconstruct the archive in numeric order, verify it,
then expand it. The expanded file is a raw 4096-byte-sector GPT image containing
`pmOS_boot` and `pmOS_root`; it is not an Android sparse image.

```bash
cat oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img.zst.part* \
  > oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img.zst
zstd -d --keep oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img.zst
# Compare this digest with the "Rootfs raw SHA-256" in MANIFEST.md.
sha256sum oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img
test "$(stat -c %s oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-boot.img)" -eq 100663296
test "$(stat -c %s oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-dtbo.img)" -eq 25165824
```

## Flash the matching set

The rootfs is written to physical `userdata`. The filtered DTBO and mainline
boot image are written to `dtbo_b` and `boot_b`. Flashing `userdata` is
destructive. Confirm that the backups above are readable before continuing.

Use userspace fastboot (`fastbootd`) for `userdata`. The bootloader path is not
the validated transport for this large image; fastbootd completed the exact
hardware-readback image in bounded sparse segments.

```bash
# The backup section leaves the phone in recovery-provided fastbootd.
fastboot getvar is-userspace  # must report: yes
fastboot getvar partition-size:userdata

# Keep sparse transfers small enough for the tested HD1913 USB path.
fastboot -S 128M flash userdata \
  oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img
fastboot reboot bootloader
fastboot getvar is-userspace  # must report: no
fastboot getvar product       # must report: msmnile
fastboot flash vbmeta_b oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-vbmeta-disabled.img
fastboot flash dtbo_b oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-dtbo.img
fastboot flash boot_b oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-boot.img
fastboot set_active b
fastboot reboot
```

If `fastboot reboot fastboot` cannot start fastbootd, the active slot does not
contain a compatible recovery. Restore or select a known-good HD1913 recovery
slot before continuing. Do not substitute a direct bootloader `userdata` flash.
`boot_a`, `dtbo_a`, Android `super` and both recovery partitions are deliberately
preserved, but Android user data is not.

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

Normal software reboot and direct bootloader/recovery selection are validated.
The recovery target is the existing Android/Lineage userdebug recovery with
authorized root ADB, not a native postmarketOS recovery image. Keep the physical
key sequence available as an independent fallback.

If the phone enumerates as Qualcomm `05c6:900e` or `05c6:9008`, inspect it
read-only only. Never issue a protocol reset, reboot or flash command in that
state. Disconnect it and use the physical HD1913 key sequence to return to
bootloader fastboot, then confirm `fastboot devices` before writing anything.
A failed Alpha boot can be recovered by restoring all saved slot-B images:

```bash
fastboot flash vbmeta_b hotdog-slot-b-backup/vbmeta_b.img
fastboot flash dtbo_b hotdog-slot-b-backup/dtbo_b.img
fastboot flash boot_b hotdog-slot-b-backup/boot_b.img
fastboot set_active b
```

Alternatively select an intact slot A or restore official software for the
exact model. Do not restore only part of the boot/DTBO/vbmeta set, and do not
flash an image from another release against this rootfs.

## Current Alpha limitations

This is not a daily-driver image. Bluetooth lifecycle is currently broken;
DisplayPort and call audio, complete telephony/data, fingerprint, Warp charging
and several audio routes remain incomplete. UFS ICE and ultrasonic proximity
work, but the current rootfs is not claimed encrypted and call-time proximity
blanking is untested without a SIM. Elliptic calibration is per-device and is
restored from <code>persist</code>; the service fails closed if a matching
calibration has not been provisioned. All four cameras capture, but application
flash synchronization and production 3A/colour remain open.
The radio bootstrap is intentionally fail-closed and does not expose
ModemManager until SIM/PDC/DMS readiness is verified. Refer to
[status.md](status.md) for the evidence-backed matrix.
