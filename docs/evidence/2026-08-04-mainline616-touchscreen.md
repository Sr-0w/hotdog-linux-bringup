# Mainline 6.16 touchscreen validation

Date: 2026-08-04

Device: OnePlus 7T Pro (`hotdog`), HD1913 rear label

Kernel: `6.16.0-sm8150`
Result: direct pmaports boot with working Samsung S6SY761 multitouch

## Scope

This run extended the already validated direct pmaports boot without changing
its initramfs, command line, root filesystem, or Android boot-image layout.
Only the source-built hotdog DTB was changed during localization. The final
cycle then booted the exact kernel and DTB extracted from the strict `r4` APK.

## Device-tree fix

The initial DTS contained a disabled `touchscreen@48` node under `i2c17`.
Enabling that child alone was insufficient because the complete bus hierarchy
was also disabled. Three controlled boots identified the required contract:

| Candidate | Controlled change | Hardware result |
|---|---|---|
| touch-v1 | Enable the S6SY761 node with schema-complete supplies and HD191x GPIO states | Direct boot and SSH remained stable; no I2C adapter appeared because `qupv3_id_2` was disabled. |
| touch-v2 | Also enable `qupv3_id_2` | `cc0000.geniqup` registered; `c80000.i2c` deferred with `Failed to get tx DMA ch`. |
| touch-v3 | Also enable `gpi_dma2` | I2C adapter 0, client `0-0048`, module `s6sy761`, and input device `event1` registered. |

The accepted source delta uses:

- QUPv3 wrapper 2 and GPI DMA controller 2;
- I2C address `0x48`;
- interrupt GPIO 122, level low;
- reset GPIO 54, default high;
- `vreg_l1c_1p8` as `vdd`;
- `vreg_l10c_3p3` as `avdd`.

The node passes the upstream `samsung,s6sy761` DT schema. Patch
`0016-arm64-dts-hotdog-enable-s6sy761-touchscreen.patch` carries the accepted
change in the reference aport.

## Strict package artifacts

| Artifact | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r4.apk` | 25,534,903 bytes | `ca4cc9ff32caac1fe1126966e681ffcf1ec827bd5d96450f81a500df63903664` |
| APK `boot/vmlinuz` | 27,572,232 bytes | `df3f119058c320e09c7372ee3cdcd5b90dd2c088d4f14e4af70831d5df7843f2` |
| APK hotdog DTB | 138,574 bytes | `ef22a1e539e28af028e48d0154ae091de79da358dd3854797a86c403dd520af3` |
| Reused pmaports initramfs | 9,478,673 bytes | `347365a8e008a4f1d8b6788a6e933945a1eb940faa6af53b4057ba92d938c0bd` |
| Partition-sized AVB `boot.img` | 100,663,296 bytes | `b90b54b4864ad265de088edf4e776751aeed805ae2201d9cb239fd55b33668ff` |

Two strict builds produced the same `r4` APK hash. The package validator now
requires the QUP, GPI DMA, I2C, regulator, pinctrl, driver-config, and module
invariants used by this hardware run.

## Direct-boot attestation

The AVB image was written only to `boot_b` and read back completely before a
single orderly reboot. The fresh boot reported:

```text
Linux version 6.16.0-sm8150 (postmarketOS@pmaports) ...
#5-oneplus-hotdog-mainline616 SMP PREEMPT 2025-08-22 17:25:08
boot_b sha256: b90b54b4864ad265de088edf4e776751aeed805ae2201d9cb239fd55b33668ff
root: /dev/loop0p2 ext4 rw
usb0: up
```

The hardware probe then registered:

```text
s6sy761 0-0048: the axis have not been set
input: s6sy761 as .../c80000.i2c/i2c-0/0-0048/input/input1
```

The warning refers to the driver's legacy `ABS_X`/`ABS_Y` check. The device
does expose the multitouch axes used by the input stack.

## Input validation

Reading `/dev/input/event1` while tapping, dragging, and using multiple fingers
produced continuous events for:

- `ABS_MT_TRACKING_ID` lifecycle;
- `ABS_MT_POSITION_X` and `ABS_MT_POSITION_Y`;
- touch major/minor dimensions and pressure;
- multiple `ABS_MT_SLOT` values.

Observed coordinates covered the panel in both axes, including values such as
`X=688, Y=1071`, `X=250, Y=1112`, and `X=980, Y=2069`. After the test,
`/proc/interrupts` recorded 729 level-triggered interrupts on GPIO 122 under
`s6sy761_irq`.

This validates controller communication, firmware integrity, IRQ delivery,
coordinate reporting, pressure, drag tracking, and multitouch slots on the
tested handset.

## Remaining touchscreen work

- validate suspend and resume;
- validate orientation and coordinate transforms in a graphical shell;
- verify behavior across every advertised contact slot;
- test other `hotdog` regional variants before generalizing the GPIO and rail
  contract.

Wi-Fi/Bluetooth, audio, GPU binding, battery/charging, modem, cameras, sensors,
USB host mode, and system suspend remain separate bring-up tasks.
