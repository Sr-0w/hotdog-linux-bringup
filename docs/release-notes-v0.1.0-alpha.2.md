# OnePlus 7T Pro postmarketOS v0.1.0-alpha.2

`v0.1.0-alpha.2` replaces Alpha 1 as the public experimental image for the
OnePlus 7T Pro HD1913 (`hotdog`). Alpha 1 omitted the filtered DTBO that was
present on the development phone during its successful boots. A clean phone
could therefore remain in fastboot after following the published guide.

Alpha 2 ships the complete atomic set:

- the postmarketOS nested-GPT system image;
- the matching 100,663,296-byte AVB boot image; and
- the hardware-validated 25,165,824-byte filtered DTBO image.

Do not mix any of these files with Alpha 1 or another build.

## Changes since Alpha 1

- Kernel package updated from `6.16.0-r108` to `6.16.0-r180`.
- Device package updated from `3-r16` to `3-r29`.
- Firmware package updated to `20241212-r7`, with the matching OxygenOS 10
  modem firmware and sensor-compatible SLPI `00083` image.
- The release packager now rejects a missing or invalid DTBO, mismatched
  internal `/boot.img`, invalid AVB, UUID mismatch, bad GPT or failed
  filesystem checks.
- The install guide now recognizes bootloader product `msmnile`, distinguishes
  bootloader fastboot from fastbootd, backs up both `boot_b` and `dtbo_b`, and
  documents complete rollback and Qualcomm `900e`/`9008` stop conditions.
- USB ACM serial, the three-position alert slider, haptics, Plasma flashlight,
  NFC reader mode and the SLPI sensor infrastructure are integrated in the
  image.
- Suspend, Wi-Fi resume, four-camera capture, pop-up camera control, charging,
  IPA/rmnet and dual-SIM discovery include the latest tracked fixes.

## Important limitations

This remains a development image for a recoverable handset. Bluetooth
initialization, UFS ICE, ultrasonic proximity, complete telephony, production
camera quality, camera-app flash synchronization, several audio routes,
fingerprint and Warp charging are not complete. The display has a known
intermittent DSI/DSC recovery issue.

The Alpha 2 artifact set passed independent offline format, hash, AVB, GPT,
filesystem, package and payload checks. The exact final image has not yet been
booted on hardware. Its individual hardware features derive from the current
evidence-backed development baseline; that distinction is intentional.

Verify `SHA256SUMS`, read the attached `INSTALL.md`, and keep both slot-B
backups before writing anything.
