# OnePlus 7T Pro (`oneplus-hotdog`)

> [!NOTE]
> This is a project-side documentation mock-up. It is not the postmarketOS
> Wiki page, an accepted pmaports port, or a supported installation guide. It
> records the hardware state validated in this repository at commit `f280c8c`
> and should not be copied to another project without independent review.

The OnePlus 7T Pro is a Qualcomm SM8150-AC handset released in 2019. This
project is bringing up a close-to-mainline Linux kernel and postmarketOS on the
device, with the eventual goal of contributing a maintainable port to
`pmaports`.

The tested handset is labelled `HD1913`, while its recovery and vendor software
identify it as `HD1911`. Results from this device must not be assumed to apply
unchanged to every regional or McLaren variant.

## Device information

| Property | Value |
|---|---|
| Manufacturer | OnePlus |
| Product | OnePlus 7T Pro |
| Codename | `hotdog` |
| Tested model | Rear label `HD1913`; recovery reports `HD1911` |
| Release year | 2019 |
| Original software | Android 10 |
| SoC | Qualcomm SM8150-AC / Snapdragon 855+ |
| CPU | Kryo 485, eight cores |
| GPU | Qualcomm Adreno 640 |
| Architecture | AArch64 |
| Memory | 8 GB; some variants have 12 GB |
| Storage | 256 GB UFS 3.0 |
| Display | 6.67-inch 1440 x 3120 AMOLED, up to 90 Hz |
| Boot layout | Unlocked Android A/B bootloader |
| Validated userspace | postmarketOS edge with OpenRC |
| Validated kernel | Mainline-oriented Linux 6.16 reference build |

## Current status

The complete image produced by the current project-side pmaports flow boots
directly from the OnePlus bootloader. It does not execute the retained Linux
4.14 recovery kernel and does not use `kexec`.

The validated image initializes the native display, enumerates UFS, discovers
the nested postmarketOS filesystems, mounts the root filesystem read-write,
completes `switch_root`, starts OpenRC, and exposes USB networking and SSH. A
fresh SSH session was established 18 seconds after reboot.

This closes the initial package-to-hardware boot milestone. The port remains a
bring-up target rather than a usable mobile operating system because most
peripherals and power-management functions are not enabled yet.

## Hardware support

| Subsystem | State | Notes |
|---|---|---|
| Direct kernel boot | Working | Linux 6.16 starts directly from `boot_b`; no downstream bridge or kexec is used. |
| postmarketOS initramfs | Working | The standard initramfs discovers the nested GPT and completes the root hand-off. |
| UFS storage | Working with a workaround | Samsung UFS enumerates; coherent DMA is temporarily constrained below 4 GiB while the UFS SMMU description is bypassed. |
| Root filesystem | Working | `pmOS_root` mounts read-write and expands to the available laboratory partition size. |
| Kernel modules | Working | The matching module tree is installed under `/usr/lib/modules/6.16.0-sm8150`. |
| USB networking | Working | CDC NCM exposes `172.16.42.1`; ping and SSH are stable. |
| USB serial | Partial | CDC ACM enumerates and `ttyGS0` is created; an interactive serial session is not validated. |
| Internal display | Partial | Native DPU, DSI, DSC, panel and fbcon initialize. Text is readable, but dense scrolling output repeats vertically. |
| Power key | Working | `pm8941_pwrkey` is exposed as an input device. |
| Touchscreen | Not enabled | No touchscreen input device is exposed by the validated image. Android identifies a Samsung `sec-s6sy761` controller. |
| GPU acceleration | Not enabled | The validated kernel reports that no GPU device was found. |
| Wi-Fi | Not enabled | No WLAN interface or rfkill device is exposed. |
| Bluetooth | Not enabled | Firmware packaging exists, but runtime support is not validated. |
| Audio | Not enabled | No ALSA sound card is exposed. |
| Battery and charging | Not enabled | No power-supply class device is exposed. |
| Modem, calls and mobile data | Not validated | Remoteproc, QRTR/QMI and modem integration remain open. |
| GNSS | Not validated | No GPS/GNSS result is available. |
| NFC | Not validated | No runtime result is available. |
| Cameras | Not validated | Camera support has not been brought up. |
| Sensors | Not validated | Accelerometer, gyroscope, magnetometer, light, proximity and related sensors remain open. |
| Haptics | Not validated | No runtime result is available. |
| Suspend and resume | Not validated | Power consumption and reliable suspend are open milestones. |
| USB host and dock | Not validated | Device-mode USB works; host mode, OTG and DisplayPort alternate mode are untested. |
| Reboot modes | Partial | Reboot to bootloader worked from an earlier kexec environment; clean direct-image bootloader and recovery reboots need validation. |

## Validated boot path

```text
OnePlus bootloader
    -> package-built Linux 6.16 kernel and source-built device tree
    -> native SM8150 display and framebuffer console
    -> UFS enumeration
    -> nested pmOS_boot and pmOS_root discovery
    -> read-write postmarketOS root filesystem
    -> OpenRC
    -> CDC NCM/ACM
    -> SSH at 172.16.42.1
```

The exact hardware-validated kernel identifies itself as:

```text
Linux hotdog 6.16.0-sm8150 #4-oneplus-hotdog-mainline616 SMP PREEMPT
```

The package-generated partition-sized AVB image has SHA256:

```text
df87c5442859caeaeba08bfe2abb4f7b723437124b9764d9bf8d63b8be7a4fca
```

It was written to `boot_b` and read back in full with the same hash before the
validated boot.

## Display status

The internal panel is driven by the native SM8150 DRM path rather than a
retained firmware framebuffer. DPU, DSI, Display Stream Compression, the panel
driver and fbcon initialize successfully. Kernel and postmarketOS initramfs
messages are readable on the physical screen.

The current mode is not ready for a graphical environment. Dense console
output is repeated vertically, so scanout geometry or console scrolling still
needs correction. GPU acceleration and a Wayland or Xwayland session have not
been validated.

## Storage status

The direct-boot kernel enumerates the Samsung UFS device and mounts the
postmarketOS filesystems. The result currently depends on a temporary DMA
workaround: when the bring-up device tree omits UFS `iommus`, coherent UFS DMA
is constrained to 32 bits. This avoids transfer-request descriptors that the
controller cannot access without the intended SMMU translation.

The final port should restore the correct Apps SMMU relationship and resolve
UFS inline-encryption integration instead of retaining the bypass and DMA32
constraint.

## USB status

The DWC3 controller is attached to Apps SMMU stream `0x140` and uses a
translated domain with `iommu.passthrough=0`. This is required for the
controller event ring and endpoint-zero transfers to work on the validated
boot path.

The resulting gadget exposes CDC NCM and ACM. The host uses `172.16.42.2`, and
the phone is reachable at `172.16.42.1` over ping and SSH. Generic DWC3, gadget
and IOMMU source is unmodified in the clean validated kernel.

## Image construction

The hardware-tested build used:

- pmbootstrap `3.10.1`;
- pmaports commit `918a1f4e4dd1ebcf0e4df226dbadc210a857fe9c`;
- ClearStaff Linux source commit
  `403b56c33e2ccdda25d90378970a5e5b928dee19`;
- an Android boot image with header version 2 and 4096-byte pages;
- a 397-byte kernel command line, below the measured 511-byte ABL limit;
- separate `pmOS_boot` and `pmOS_root` filesystems;
- a deterministic 96 MiB AVB envelope for the OnePlus boot partition.

The normal device-package flow builds the kernel, device tree, initramfs,
Android image and split filesystems. The final AVB wrapping and current storage
placement are still laboratory integration steps.

## Installation status

There is no supported end-user installation procedure yet. The validated
laboratory deployment writes a nested GPT containing `pmOS_boot` and
`pmOS_root` to the beginning of the dedicated test phone's `userdata`
partition, then writes the validated AVB image to `boot_b`.

> [!WARNING]
> This layout is destructive to user data and is intended only for the
> dedicated development handset. It must not be presented as the final
> postmarketOS installation method.

The tested OnePlus bootloader does not provide a dependable unattended A/B
fallback. A failed slot can remain selected at retry count zero and display the
red boot-failure screen instead of selecting a known-good slot. A verified
recovery image and stock DTBO are therefore retained during development.

## Packaging and upstreaming status

The repository contains public snapshots of:

- `device-oneplus-hotdog`;
- `linux-oneplus-hotdog-mainline616`;
- firmware packaging for the device;
- scripts that assemble and validate the complete image.

These packages demonstrate a reproducible package-to-hardware path, but they
are not accepted pmaports packages. The intended initial submission category
is `device/testing`.

Before submission, the device-specific Linux reference package should be
migrated to the shared `linux-postmarketos-qcom-sm8150` package. Temporary UFS
DMA and SMMU workarounds, UFS ICE removal, debug arguments, the laboratory
storage layout, firmware provenance, and clean reboot paths also need to be
resolved.

## Development priorities

1. Correct the native display geometry and validate a graphical session.
2. Enable the Samsung touchscreen and remaining hardware keys.
3. Replace the temporary UFS DMA/SMMU path with a maintainable description.
4. Enable battery reporting and charging.
5. Bring up Wi-Fi and Bluetooth with reviewed firmware packaging.
6. Enable GPU acceleration, audio and remote processors.
7. Validate modem, sensors, cameras, suspend/resume and USB host mode.
8. Replace the laboratory installation method with a documented pmaports flow.
9. Rebase the maintained changes onto the shared SM8150 kernel package.

## Sources and related work

- [Public bring-up repository](https://github.com/Sr-0w/hotdog-linux-bringup)
- [Hardware support status at the validated revision](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/status.md)
- [Package-to-hardware evidence](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/evidence/2026-08-03-mainline616-pmaports.md)
- [Direct UFS and rootfs evidence](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/evidence/2026-08-03-direct-mainline-rootfs.md)
- [Direct USB networking and SSH evidence](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/evidence/2026-08-03-direct-mainline-usb.md)
- [Native display evidence](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/evidence/2026-08-03-native-display.md)
- [pmaports upstreaming plan](https://github.com/Sr-0w/hotdog-linux-bringup/blob/f280c8c/docs/pmaports-upstreaming.md)
- [Existing postmarketOS device page](https://wiki.postmarketos.org/wiki/OnePlus_7T_Pro_(oneplus-hotdog))

The existing device page lists BotchedRPR as a contributor. The validated Linux
6.16 source baseline is derived from work published by ClearStaff. Contributor
and authorship attribution should be checked against the relevant repository
histories before any external documentation is updated.
