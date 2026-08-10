# Release installation and versioning

## Scope

Release images are experimental postmarketOS builds for the **OnePlus 7T Pro
HD1913** with the `hotdog` codename and an **unlocked bootloader**. Do not use
them on another OnePlus model solely because it looks similar. A wrong boot
image or a failed test kernel can require fastboot or recovery to regain access.

The project publishes a boot image and rootfs image as one atomic release set.
The boot command line contains the UUIDs of the `pmOS_boot` and `pmOS_root`
filesystems inside the rootfs image. Never mix a boot image from one release
with a rootfs asset from another release.

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
5. Enter bootloader fastboot and verify the target. Stop unless it reports an
   unlocked `hotdog` device.

```bash
fastboot devices
fastboot getvar product
fastboot getvar unlocked
```

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

## Flash the matching pair

The rootfs is written to physical `super`. The mainline boot image is written
to `boot_b`, leaving `boot_a` untouched as an additional recovery option.

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

Do not repeatedly reset a device that has enumerated as Qualcomm `900e`.
Disconnect it, use the physical HD1913 key sequence to return to bootloader
fastboot, then confirm `fastboot devices` before writing anything. A failed
Alpha boot can be recovered by reflashing the same complete release pair,
switching to an intact `boot_a`, or restoring official software for the exact
model. Do not flash a boot image from another release against this rootfs.

## Current Alpha limitations

This is not a daily-driver image. Suspend/resume, DisplayPort audio, UFS ICE,
telephony, front and ultra-wide cameras, sensors, NFC, fingerprint, and several
audio paths remain incomplete or untested. Main and telephoto capture work, but
autofocus and production colour calibration remain incomplete. Refer to
[status.md](status.md) for the evidence-backed matrix.
