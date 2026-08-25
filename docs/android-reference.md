# Android reference collection

Last reviewed: 2026-08-25

Android is used as a hardware-description reference before Linux testing. The
resulting dumps are device-specific and remain outside Git.

Useful facts to capture include:

- exact model and regional variant
- Android build fingerprint and security patch level
- bootloader slot and unlock state
- `ro.boot.*` device, project, hardware, DTB, and DTBO identifiers
- panel name, resolution, refresh rates, and HDR modes
- touch-controller identity and GPIO assignments
- battery, charger, USB role, audio, camera, modem, Wi-Fi, and Bluetooth data
- firmware file names and vendor configuration paths

The repository provides read-only collectors for a running Android system:

```bash
./scripts/collect-adb-reference.sh
./scripts/collect-fastboot-reference.sh
```

For an offline OxygenOS dump, mount the extracted logical partitions read-only
and generate a hash-only hardware inventory:

```bash
./scripts/inventory-oxygenos-assets.py \
  --root vendor=/mnt/oxygenos/vendor \
  --root odm=/mnt/oxygenos/odm \
  --images /path/to/decrypted-images \
  > oxygenos-hardware-assets.json
```

The inventory separates reusable firmware and calibration from 4.14 kernel
modules and Android HAL binaries. The latter two are reference inputs and
cannot be loaded directly into the mainline postmarketOS image.

Review their output before sharing it. Remove serial numbers, network
identifiers, account information, and proprietary blobs.

Android behavior is a reference, not proof that a corresponding mainline
driver is correct.

The current local truth set includes the recovered OxygenOS 10.0.13 vendor
partition and a publicly downloaded multi-region OnePlus 7T Pro update archive
with OxygenOS 11.0.9.1 and 12 F.22 packages. Both remain ignored inputs. Every
finding must identify the exact regional package/version and hash rather than
refer generically to “OxygenOS”, because their DSP and modem payloads differ.
