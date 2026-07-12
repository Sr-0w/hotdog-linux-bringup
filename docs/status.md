# Hardware support status

Last updated: 2026-07-12

## Tested hardware

| Item | Value |
|---|---|
| Device | OnePlus 7T Pro |
| Tested model | HD1913 rear label; recovery reports HD1911 |
| Codename | `hotdog` |
| SoC | Qualcomm SM8150-AC / Snapdragon 855+ |
| Architecture | AArch64 |
| Bootloader | Unlocked A/B bootloader |
| Userspace | postmarketOS edge, OpenRC |
| Mainline base | postmarketOS Qualcomm SM8150 Linux 6.17 branch |
| Bridge base | Lineage/OpenELA-derived Linux 4.14.357 |

Other `hotdog` variants may differ in modem, panel, firmware, and bootloader
behavior. Do not assume that an HD1913 result applies unchanged to every model.
The model mismatch above is reported explicitly because the vendor/recovery
identity is HD1911 even though the physical handset is labelled HD1913.

## Mainline support matrix

| Subsystem | State | Evidence or limitation |
|---|---|---|
| Kernel entry | Working through kexec | The 4.14 bridge loads and executes Linux 6.17. |
| K1 kernel package | Current r4 build evidence, not hardware-tested | Two `6.17.0-r4` builds in the tested pmbootstrap environment produced byte-identical `27,172,035`-byte APKs, SHA256 `74d7cff718be9a06b8858360fe56c1ccd8d1fd7653151546b0480029694d803e`. Their `28,901,384`-byte `vmlinuz` is `7fba453fd960515b526e7f562b9c682078ad800f27e5861db431ad9d7d4532b5`; the installed transformed DTB is `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440`. This does not establish hardware behavior or reproducibility with another toolchain. |
| Device package metadata | Structural validation only | The version-2 device metadata uses `kernel-cmdline.conf` containing `clk_ignore_unused` and has passed `dint` structural validation. This does not validate hardware; `deviceinfo_drm` must remain absent from a submission until the runtime DRM path works. |
| Direct-boot candidates | Prepared, not hardware-tested | Historical single-DTB D1 remains first. D1-pack is a single-variable DTB-selection fallback only after a recorded D1 result; the package-built candidate is a reproducibility control only after D1 validation. |
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
| Reboot | Historical module result; r4 untested | Under the historical module configuration, the exact 6.17 `qcom-wdt.ko` created `/dev/watchdog*` and produced a physical reboot. The r4 package has no watchdog module member because `CONFIG_QCOM_WDT=y`; built-in watchdog behavior is not hardware-validated. |
| Reboot mode | Staging patch only, not hardware-validated | The observed `cf63ae...` DTB and the r4 K1 package do not include PON reboot-mode properties. The separate SM8150 staging patch adds `mode-bootloader = <2>` and `mode-recovery = <1>` and has offline `fdtget` evidence only. This does not prove RESTART2 fastboot works. |
| Touch | Not enabled | Android identifies a Samsung `sec-s6sy761` controller. |
| Firmware packages | Packaging complete, runtime not validated | `firmware-oneplus-hotdog` `20241212-r0` produces eight APKs and 16 payloads, all under `/usr/lib/firmware`. This proves package layout, not peripheral operation or redistribution approval. |
| Wi-Fi/Bluetooth | Not validated | The usrmerged firmware packages exist; runtime loading, enumeration, and connectivity remain pending. |
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

1. Boot D1 persistently from `boot_b`: the exact K1 payload in an Android
   header v2 image with stock offsets, with the no-paint bridge rescue watcher
   confirmed ready with the pinned restore hash before the write.
2. Accept D1 only after a fresh postmarketOS SSH boot ID reports kernel
   `6.17.0-sm8150` and the expected wrapper, slot-B, and serial command-line
   markers; ADB, telnet, ping, or a returned 4.14 bridge are diagnostics, not
   success.
3. Treat `fastboot boot` as non-authoritative on this ABL: valid controls return
   `Load Error`, while one D1 transfer reported `OKAY` without leaving fastboot.
4. Only after D1 has a recorded result, use
   `test-mainline617-direct-d1-pack.sh` as the single-variable DTB-pack fallback.
   This prepared image has not been tested on hardware.
5. Treat `2026-07-11-224500-mainline617-pmaports-k1-direct` as the historical
   r0 package control. After D1 has a recorded result, generate a separate r4
   package candidate, record its kernel, installed DTB, raw-image, and AVB
   hashes, and test it without reusing the r0 identity. The same-environment r4
   package reproducibility check is complete; the direct image is not.
6. After D1, boot a DTB containing the hotdog-only PON reboot-mode properties
   and verify whether Linux reboot-to-bootloader and reboot-to-recovery select
   the expected RESTART2 modes.
