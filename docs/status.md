# Hardware support status

Last updated: 2026-07-11

## Tested hardware

| Item | Value |
|---|---|
| Device | OnePlus 7T Pro |
| Tested model | HD1913 |
| Codename | `hotdog` |
| SoC | Qualcomm SM8150-AC / Snapdragon 855+ |
| Architecture | AArch64 |
| Bootloader | Unlocked A/B bootloader |
| Userspace | postmarketOS edge, OpenRC |
| Mainline base | postmarketOS Qualcomm SM8150 Linux 6.17 branch |
| Bridge base | Lineage/OpenELA-derived Linux 4.14.357 |

Other `hotdog` variants may differ in modem, panel, firmware, and bootloader
behavior. Do not assume that an HD1913 result applies unchanged to every model.

## Mainline support matrix

| Subsystem | State | Evidence or limitation |
|---|---|---|
| Kernel entry | Working through kexec | The 4.14 bridge loads and executes Linux 6.17. |
| Device tree | Bring-up quality | Boots with temporary memory, SMMU, and ICE workarounds. |
| UFS | Working | Samsung UFS controller probes and exposes all Android partitions. |
| postmarketOS root | Working | Nested `pmOS_root` mounts read-write as `/dev/loop1`. |
| postmarketOS boot | Working | Nested `pmOS_boot` mounts as `/dev/loop0`. |
| OpenRC userspace | Working | Core boot, NetworkManager, SSH, and local services start. |
| USB NCM | Working | The device is reachable at `172.16.42.1`. |
| USB ACM | Working | A serial shell is exposed on `ttyGS0`. |
| Early console | Partial | Kernel text is visible before the display path is lost. |
| DRM/panel | Not working | Mainline display clocks and the panel pipeline are not enabled. |
| Framebuffer | Not working | `simple-framebuffer` fails to reserve its memory with `-12`. |
| RAM | Partial | Approximately 448 MiB is available with the low-bank map. |
| Apps SMMU | Not working | Registration fails with `-EINVAL`; selected clients bypass it. |
| UFS ICE | Not working | ICE probe fails; UFS currently runs without the ICE dependency. |
| Kernel modules | Incomplete | The installed rootfs still contains downstream 4.14 modules. |
| Reboot | Not working in the validated build | The kexec-booted kernel shuts userspace down but lacks a built-in APSS watchdog restart handler. A `CONFIG_QCOM_WDT=y` candidate is prepared but not hardware-validated. |
| Touch | Not enabled | Android identifies a Samsung `sec-s6sy761` controller. |
| Wi-Fi/Bluetooth | Not validated | Firmware packaging exists, runtime support is pending. |
| Audio | Not validated | Codec, routing, and userspace configuration remain open. |
| Modem | Not validated | QRTR/QMI and modem firmware integration remain open. |
| Cameras | Not validated | Camera pipeline support is not started. |
| Charging/battery | Not validated | Power-supply and charging behavior need dedicated testing. |
| USB host/dock | Not validated | Device-role USB is proven; host-role operation is not. |

## Downstream support

The downstream 4.14 kernel remains useful as a bridge and rescue environment.
It provides UFS, USB networking, SSH, USB ACM, simplefb/fbcon, and a working
downstream-only MSM DRM path capable of showing a test pattern and text
console. That path is a diagnostic reference, not a publication target.

Downstream support is not the project endpoint. New functionality should be
implemented in pmaports and the mainline-oriented kernel path whenever
possible.

## Definition of the next milestone

The next milestone is a reproducible pmaports build that boots mainline without
the downstream kexec bridge, exposes the complete RAM map, and retains USB SSH.
Display support can then be developed without losing the remote debug channel.

## Current validation queue

1. Boot a single-variable Linux 6.17 control with `CONFIG_QCOM_WDT=y` through
   kexec, verify the driver probes, and confirm a software reboot returns to
   fastboot.
2. Revalidate the exact known-good K1 payload and userspace path.
3. Test D1: the exact K1 payload in an Android header v2 image with stock
   offsets, first as a temporary boot and without flashing a partition.
