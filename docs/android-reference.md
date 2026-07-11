# Android reference collection

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

The repository provides read-only collectors:

```bash
./scripts/collect-adb-reference.sh
./scripts/collect-fastboot-reference.sh
```

Review their output before sharing it. Remove serial numbers, network
identifiers, account information, and proprietary blobs.

Android behavior is a reference, not proof that a corresponding mainline
driver is correct.
