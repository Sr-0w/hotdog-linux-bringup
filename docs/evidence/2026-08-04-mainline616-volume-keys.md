# Mainline 6.16 hardware-key integration

Date: 2026-08-04

Device: OnePlus 7T Pro HD1913 (`hotdog`)

Result: the reproducible pmaports `r6` package registered Power, Volume Down,
Volume Up, and the existing S6SY761 touchscreen after a direct boot from the
OnePlus bootloader. At that revision the physical press/release capture for the
two volume keys was still pending. Later hardware validation corrected the
Volume Down wiring and completed physical validation of both volume buttons;
see the final section below.

## Device-tree fix

The accepted `r5` image exposed only the PM8150 PON Power key. Revision `r6`
added the two missing volume-key paths without changing the kernel source,
initramfs, command line, or boot-image layout:

- PM8150 PON `resin` was enabled as `KEY_VOLUMEDOWN`;
- PM8150 GPIO 6 was configured as an active-low, pulled-up input;
- a `gpio-keys` child mapped that GPIO to `KEY_VOLUMEUP` and marked it as a wake
  source;
- the existing PON Power key was explicitly kept enabled.

The change is carried by
`0018-arm64-dts-hotdog-enable-volume-keys.patch`. The package validator rejects
builds that lose the required input drivers, key codes, GPIO binding, pinctrl
state, pull-up, or wake-source property.

The `r6` Volume Down mapping is historical rather than the final board
wiring. A later physical check showed that pressing Volume Down changed neither
the PM8150 PON `RESIN` real-time state nor its interrupt count. The current
device tree therefore maps Volume Down to PM8150 GPIO7, while Volume Up remains
on PM8150 GPIO6.

## Reproducible package

Two independent strict pmbootstrap builds started from clean buildroots. Both
printed `hotdog mainline 6.16 build contract: PASS` and produced the same APK
byte-for-byte:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r6.apk` | 25,535,120 bytes | `17af600197825164ceb791606cbb00cd7f19d587746432fd58140c5d24c85e6e` |
| `boot/vmlinuz` | 27,572,232 bytes | `b35176a252b10d51d33b182e4ca7e1ab4ceadccf191cba987a359c0093a2f5d5` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 139,174 bytes | `fec8bf455c4c922737d7676d9dc96e9220ccea3eb87297665c8b19bee577e106` |

The exact APK kernel and DTB were combined with the validated pmaports
initramfs. The resulting 96 MiB AVB image has SHA256
`33e20fce76b38122fe4b5fb8427eab044e7c594649e105e20ff9284e4e570f2e`.
The complete `boot_b` partition readback produced the same hash before one
supervised reboot.

## Direct-boot attestation

The fresh `r6` boot reported:

```text
Linux hotdog 6.16.0-sm8150 #7-oneplus-hotdog-mainline616 SMP PREEMPT ...
boot_b sha256: 33e20fce76b38122fe4b5fb8427eab044e7c594649e105e20ff9284e4e570f2e
root: /dev/loop0p2 ext4 rw
```

The source-built `r6` DTB registered four input devices:

| Event | Driver | Linux code |
|---|---|---|
| `event0` | `pm8941_pwrkey` | `KEY_POWER` (116) |
| `event1` | `pm8941_resin` | `KEY_VOLUMEDOWN` (114) |
| `event2` | `gpio-keys` | `KEY_VOLUMEUP` (115) |
| `event3` | `s6sy761` | Touch and multitouch axes |

The touchscreen module, USB networking, read-write root filesystem, DRM render
node, Adreno driver, and GMU firmware remained available after the change.

## Later physical validation — 2026-08-07

The `r6` registration result above must not be mistaken for validation of its
original Volume Down wiring. Subsequent checks on the same physical handset
established the final input result:

- **Volume Down:** PM8150 GPIO7 / `KEY_VOLUMEDOWN`; physical button operation is
  hardware-validated and functional.
- **Volume Up:** PM8150 GPIO6 / `KEY_VOLUMEUP`; physical button operation is
  hardware-validated and functional.
- **Old Volume Down path:** PM8150 PON `RESIN`; hardware-invalidated and no
  longer used for the button.

Both physical volume buttons can therefore be treated as supported for normal
runtime input. Wake-source behavior, behavior across system suspend/resume, and
full userspace policy validation remain separate tests and are not implied by
this result.

## Remaining validation

- verify key behavior while the display is blanked;
- validate key wake behavior and touchscreen operation across suspend/resume;
- validate userspace key mappings under the selected graphical shell.
