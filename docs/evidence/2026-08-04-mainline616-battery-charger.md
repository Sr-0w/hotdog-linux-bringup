# Mainline 6.16 battery and charger validation

Date: 2026-08-04

Device: OnePlus 7T Pro HD1913 (`hotdog`)

Result: a clean revision derived directly from the accepted `r6` source enables
the PM8150B fuel gauge and SMB5 charger. It direct-boots from the OnePlus
bootloader, retains USB networking and SSH, and exposes both power-supply class
devices.

## Isolated source change

The package starts from commit `952a98e`, the exact `r6` source baseline. It
adds only `0019-arm64-dts-hotdog-enable-battery-charger.patch`:

- a non-removable 4085 mAh lithium-ion-polymer battery description;
- 3.30 V and 4.42 V design limits;
- conservative 1.50 A and 4.40 V charging limits;
- enabled PM8150B Gen4 fuel-gauge and SMB5 charger nodes;
- explicit `monitored-battery` and `power-supplies` links.

No charger-driver source, kernel configuration, initramfs, command line, boot
header, modem, or audio change is included. The package validator checks the
four existing power-supply driver options and every added DT property and
phandle.

## Build identity

Two strict pmbootstrap builds, each starting from a freshly reset buildroot,
printed `hotdog mainline 6.16 build contract: PASS` and produced byte-identical
APKs:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r7.apk` | 25,535,717 bytes | `7443a6e60eea3001370901a3a39064fd4a72909175a34cb99a6f9ee8b05b2e84` |
| `boot/vmlinuz` | 27,572,232 bytes | `a295b1c7723c73aaabf546697a5c1f393092771c6164746f72426510f0b1c101` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 139,672 bytes | `17e7dabb69f8376cbd294e82b01fcbd797d7bcc05d5f5a31b42939bf86ddad19` |

The two APK files both measured 25,535,717 bytes and both had SHA256
`7443a6e60eea3001370901a3a39064fd4a72909175a34cb99a6f9ee8b05b2e84`.

The rebuilt kernel has the same size, `0x80000` load offset, and `0x1ad0000`
Image window as `r6`. A byte comparison found only 24 changed bytes: the two
embedded `#7` to `#8` build-version updates and the corresponding build ID.

The package kernel and DTB were assembled with the exact accepted `r6`
initramfs and command line. The resulting 96 MiB AVB image has SHA256
`dbc5210987b791774e67e7a6ad5fd796ecf950fca5ebe8e0a414f6112009c29f`.
The complete image was written to and read back from `boot_b` with that hash.

## Hardware result

The fresh boot ID was `f1f13f69-4039-44c8-9f88-a454c70181ae` and the running
kernel reported:

```text
Linux hotdog 6.16.0-sm8150 #8-oneplus-hotdog-mainline616 SMP PREEMPT ...
```

USB networking and SSH returned immediately. The kernel registered:

```text
/sys/class/power_supply/pm8150b-charger
/sys/class/power_supply/qcom-battery
```

A 60-second read-only trace captured 31 samples. Battery capacity remained at
99 percent and temperature at 24.0 C. Reported battery voltage ranged from
4,472,400 to 4,492,664 uV; USB input ranged from 4,784,416 to 4,790,656 uV and
95,371 to 95,761 uA. The charger advertised a 250,000 uA input limit.

## Remaining power work

The fuel-gauge voltage is consistently above the 4.42 V design value while the
battery reports `Discharging` and the charger reports `Charging`. The next
power experiment must therefore isolate the upstream SMB5 conversion and
limit-programming correction. Charging policy, unplug/replug transitions,
low-battery behavior, thermal limits, and suspend/resume are not yet validated.
