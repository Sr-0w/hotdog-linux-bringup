# OnePlus 7T Pro (`oneplus-hotdog`)

> [!NOTE]
> Project-side preview of a possible device page. This file is not the
> postmarketOS Wiki page and does not describe an accepted pmaports port.
> Status values reflect the current hardware-tested public baseline.

![OnePlus 7T Pro booting postmarketOS](https://wiki.postmarketos.org/wiki/Special:Redirect/file/hotdog-mainline.jpg)

## Device

| | OnePlus 7T Pro |
|---|---|
| **Manufacturer** | OnePlus |
| **Name** | 7T Pro |
| **Codename** | `oneplus-hotdog` |
| **Model** | `HD1913` tested; recovery reports `HD1911` |
| **Released** | 2019 |
| **Type** | Handset |
| **Chipset** | Qualcomm Snapdragon 855+ (SM8150-AC), covered by the [SM8150 platform page](https://wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_855_(SM8150)) |
| **CPU** | 1x 2.96 GHz, 3x 2.42 GHz and 4x 1.78 GHz Kryo 485 |
| **GPU** | Adreno 640 |
| **Display** | 1440 x 3120 AMOLED, 90 Hz, 6.67 inch |
| **Storage** | 256 GB UFS 3.0 |
| **Memory** | 8/12 GB |
| **Architecture** | AArch64 |
| **Original software** | Android 10 on Linux 4.14 |
| **Extended version** | Android 12 |
| **FOSS bootloader** | No |
| **postmarketOS category** | Testing target; not merged into pmaports |
| **Booting** | Yes |
| **pmOS kernel** | Linux 6.16.0, out-of-tree reference package |
| **Device package** | `device-oneplus-hotdog` (out-of-tree) |
| **Kernel package** | `linux-oneplus-hotdog-mainline616` (out-of-tree) |
| **Firmware package** | `firmware-oneplus-hotdog` (out-of-tree) |
| **Prebuilt images** | No |

## Features

The status terms below follow the postmarketOS device-page convention:
**Works**, **Partial**, **Broken**, **Untested**, and **N/A**.

### Main features

| Feature | Status | Notes |
|---|---|---|
| Flashing with pmbootstrap | Partial | The exact pmaports output boots, but the current deployment still uses project-side assembly and guarded flashing helpers. |
| USB networking | Works | CDC NCM, ping and SSH are stable at `172.16.42.1`. |
| Internal storage | Partial | UFS and the read-write rootfs work with a temporary DMA32/SMMU workaround. |
| Battery | Partial | Battery reporting and conservative SMB5 charging limits work; transitions, termination, thermal policy, and suspend remain open. |
| Screen | Works | Native KMS produces correct 1440x3120 scanout under `kmscube`, Weston, and Plasma Mobile at 60 Hz. The 90 Hz mode is not yet validated. |
| Touchscreen | Works | S6SY761 multitouch works with correct graphical orientation under Weston and Plasma Mobile. Suspend/resume remains open. |
| Graphical interface | Works | postmarketOS Plasma Mobile 6.7.3 runs through `tinydm` with accelerated KWin/Wayland rendering. |
| Physical keyboard | N/A | |
| Touchpad | N/A | |
| Stylus | N/A | |

### Multimedia

| Feature | Status | Notes |
|---|---|---|
| 3D acceleration | Works | Turnip Vulkan, physical `kmscube`, Weston, and Plasma Mobile render through the Adreno 640 / Freedreno `FD640`. |
| Audio | Broken | No ALSA sound card is exposed. |
| Cameras | Untested | Camera support has not been brought up. |
| Camera flash | Untested | |

### Connectivity

| Feature | Status | Notes |
|---|---|---|
| Wi-Fi | Broken | No WLAN or rfkill device is exposed. |
| Bluetooth | Broken | Firmware is packaged, but runtime support is not enabled. |
| Ethernet | Untested | USB host mode has not been validated. |
| GPS | Untested | |
| NFC | Untested | |

### Modem

| Feature | Status | Notes |
|---|---|---|
| Calls | Untested | Modem and remoteproc integration remain open. |
| SMS | Untested | |
| Mobile data | Untested | |

### Miscellaneous and sensors

| Feature | Status | Notes |
|---|---|---|
| Full-disk encryption | Untested | |
| USB OTG | Untested | Device-mode USB works; host mode is untested. |
| HDMI/DisplayPort | Untested | DisplayPort alternate mode is untested. |
| Fingerprint reader | Untested | |
| Accelerometer | Untested | |
| Magnetometer | Untested | |
| Ambient light | Untested | |
| Proximity | Untested | |
| Hall effect | Untested | |
| Haptics | Untested | |
| Barometer | Untested | |

> [!NOTE]
> This device is based on the Snapdragon 855 platform. The
> [SM8150 page](https://wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_855_(SM8150))
> documents common SoC support; a feature working on another SM8150 device does
> not establish that it works on `hotdog`.

## About

The OnePlus 7T Pro now boots a package-built Linux 6.16 kernel directly from
the OnePlus bootloader. The tested path does not execute the retained Linux
4.14 recovery kernel and does not use `kexec`.

The standard postmarketOS initramfs enumerates UFS, discovers the nested
`pmOS_boot` and `pmOS_root` filesystems, mounts the root filesystem read-write,
completes `switch_root`, starts OpenRC, and exposes USB networking and SSH. The
validated package boot reached SSH 18 seconds after reboot.

The port is not ready for normal use. Display output is suitable for kernel and
userspace diagnostics, but the panel geometry remains imperfect and no
graphical session has been validated. Touch, GPU acceleration, battery,
charging, Wi-Fi, Bluetooth, audio and the modem still require device-specific
enablement.

## Contributors

- [BotchedRPR](https://wiki.postmarketos.org/wiki/User:BotchedRPR)
- [SrOw](https://wiki.postmarketos.org/wiki/User:SrOw)

Related kernel and device-tree work is derived from the public ClearStaff
SM8150 tree. Authorship should remain attributed through the relevant commit
history.

## Maintainer(s)

- [SrOw](https://wiki.postmarketos.org/wiki/User:SrOw)

## Users owning this device

On the wiki this section is generated by `{{Device owners}}` from user pages.

## How to enter flash mode

### Fastboot mode

1. Power the device off.
2. Hold **Volume Up**, **Volume Down**, and **Power**.
3. Release the buttons when the Fastboot `START` screen appears.

An already running development image may also request the bootloader with
`reboot bootloader` when the kernel restart path is functional.

> [!WARNING]
> The tested bootloader does not provide a dependable unattended A/B fallback.
> A failed slot can remain selected at retry count zero and show the red
> boot-failure screen instead of selecting a known-good slot.

## Installation

There is no supported end-user installation procedure yet. The device and
kernel packages are public development snapshots, but they have not been
merged into pmaports and cannot currently be selected from a normal
`pmbootstrap init` session.

The validated laboratory installation uses the package-generated kernel, DTB,
standard postmarketOS initramfs and split filesystems. A nested GPT containing
`pmOS_boot` and `pmOS_root` is written to the dedicated test phone's
`userdata`, and a deterministic partition-sized AVB image is written to
`boot_b`.

> [!WARNING]
> The current storage layout destroys Android user data and is intended only
> for a dedicated development handset. It is not the proposed final
> postmarketOS installation method.

The exact validated AVB image has SHA256:

```text
df87c5442859caeaeba08bfe2abb4f7b723437124b9764d9bf8d63b8be7a4fca
```

It was read back from `boot_b` with the same hash before the successful boot.
The complete build and hardware record is available in the
[package-to-hardware evidence](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/evidence/2026-08-03-mainline616-pmaports.md).

## Known issues

- **Display:** native DPU, DSI, DSC and fbcon work, but dense console output is
  repeated vertically.
- **UFS:** storage works only with a temporary coherent DMA32 constraint while
  the UFS SMMU relationship is bypassed.
- **UFS ICE:** inline-encryption integration is not working in the validated
  configuration.
- **USB serial:** CDC ACM and `ttyGS0` enumerate, but an interactive session has
  not been validated.
- **Reboot modes:** clean direct-image reboot to bootloader and recovery still
  needs validation.
- **Installation:** the nested GPT in `userdata` is a laboratory layout.
- **Firmware:** package layout is validated, but peripheral runtime support,
  provenance and redistribution review are incomplete.

## Development

The current package-to-hardware baseline is maintained in
[Sr-0w/hotdog-linux-bringup](https://github.com/Sr-0w/hotdog-linux-bringup).
The intended initial pmaports target is `device/testing`.

Before submission, the device-specific Linux reference package should be
migrated into the shared `linux-postmarketos-qcom-sm8150` package. Temporary
UFS/SMMU workarounds, debug arguments, firmware review, the installation layout
and clean reboot paths also need to be resolved.

## See also

- [OnePlus 7 Pro (`oneplus-guacamole`)](https://wiki.postmarketos.org/wiki/OnePlus_7_Pro_(oneplus-guacamole))
- [OnePlus 7/7 Pro/7T family](https://wiki.postmarketos.org/wiki/OnePlus_7_(oneplus-guacamoleb))
- [Qualcomm Snapdragon 855 (SM8150)](https://wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_855_(SM8150))
- [Xiaomi Mi 9 (`xiaomi-cepheus`)](https://wiki.postmarketos.org/wiki/Xiaomi_Mi_9_(xiaomi-cepheus))
- [Hardware support status](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/status.md)
- [Direct display evidence](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/evidence/2026-08-03-native-display.md)
- [Direct UFS and rootfs evidence](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/evidence/2026-08-03-direct-mainline-rootfs.md)
- [Direct USB and SSH evidence](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/evidence/2026-08-03-direct-mainline-usb.md)
- [pmaports upstreaming plan](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/pmaports-upstreaming.md)
