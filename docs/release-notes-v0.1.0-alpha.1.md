# OnePlus 7T Pro postmarketOS v0.1.0-alpha.1

`v0.1.0-alpha.1` is the first public experimental image release for the
OnePlus 7T Pro HD1913 (`hotdog`). It is built around the R108 mainline Linux
6.16 hardware milestone and postmarketOS Plasma Mobile.

## Included experience

- Direct mainline boot from the OnePlus bootloader.
- Plasma Mobile with a touch-first application set, Discover, Flatpak support,
  Konsole, browser, file manager, camera applications, and mobile utilities.
- Native display, accelerated Adreno graphics, touchscreen, hardware keys,
  UFS storage, USB networking/SSH, Wi-Fi, Bluetooth, speakers, microphone,
  battery reporting, USB-C dual role, USB 3, and DisplayPort video.
- Main IMX586 and telephoto S5K3M5 RAW capture with Plasma Camera/libcamera
  integration. Main autofocus remains incomplete.
- R108 clean software reboot fix for the SM8150 download-mode register.

## Important limitations

This is an Alpha image for a dedicated or recoverable test handset. System
suspend/resume, DisplayPort audio, UFS ICE, telephony, front/ultra-wide cameras,
sensors, NFC, fingerprint, earpiece/headset paths, and OnePlus Warp charging
are not complete. Dynamic 90 Hz switching works, but its wake path remains
unreliable.

## Installation

Use only the boot image and rootfs image attached to this exact release tag.
They are UUID-bound and intentionally cannot be mixed with any other build.
Verify `SHA256SUMS`, then follow
[the release installation guide](release-install.md).

The initial account is `user` with password and Plasma PIN `147147`. Change
both before using any untrusted network.

## Validation contract

Before publishing, the release assets are checked for:

- AVB footer and hash-descriptor validity;
- a 100,663,296-byte boot image;
- matching boot/root UUIDs between Android command line and nested GPT;
- matching kernel and hotdog DTB between the boot image and the shipped R108
  APK;
- read-only GPT and ext filesystem checks; and
- SHA-256 hashes for every uploaded file.
