# Mainline 6.16 hardware-key integration

Date: 2026-08-04

Device: OnePlus 7T Pro HD1913 (`hotdog`)

Result: the reproducible pmaports `r6` package registers Power, Volume Down,
Volume Up, and the existing S6SY761 touchscreen after a direct boot from the
OnePlus bootloader. Physical press/release capture for the two volume keys is
the remaining validation step.

## Device-tree fix

The accepted `r5` image exposed only the PM8150 PON Power key. Revision `r6`
adds the two missing volume-key paths without changing the kernel source,
initramfs, command line, or boot-image layout:

- PM8150 PON `resin` is enabled as `KEY_VOLUMEDOWN`;
- PM8150 GPIO 6 is configured as an active-low, pulled-up input;
- a `gpio-keys` child maps that GPIO to `KEY_VOLUMEUP` and marks it as a wake
  source;
- the existing PON Power key is explicitly kept enabled.

The change is carried by
`0018-arm64-dts-hotdog-enable-volume-keys.patch`. The package validator rejects
builds that lose the required input drivers, key codes, GPIO binding, pinctrl
state, pull-up, or wake-source property.

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

The fresh boot reported:

```text
Linux hotdog 6.16.0-sm8150 #7-oneplus-hotdog-mainline616 SMP PREEMPT ...
boot_b sha256: 33e20fce76b38122fe4b5fb8427eab044e7c594649e105e20ff9284e4e570f2e
root: /dev/loop0p2 ext4 rw
```

The source-built DTB registered four input devices:

| Event | Driver | Linux code |
|---|---|---|
| `event0` | `pm8941_pwrkey` | `KEY_POWER` (116) |
| `event1` | `pm8941_resin` | `KEY_VOLUMEDOWN` (114) |
| `event2` | `gpio-keys` | `KEY_VOLUMEUP` (115) |
| `event3` | `s6sy761` | Touch and multitouch axes |

The touchscreen module, USB networking, read-write root filesystem, DRM render
node, Adreno driver, and GMU firmware remained available after the change.

## Remaining validation

- capture physical press and release events for both volume keys;
- verify key behavior while the display is active and blanked;
- validate key wake behavior and touchscreen operation across suspend/resume;
- validate userspace key mappings under the selected graphical shell.
