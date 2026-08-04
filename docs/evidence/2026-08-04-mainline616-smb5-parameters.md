# Mainline 6.16 SMB5 parameter correction

Date: 2026-08-04

Device: OnePlus 7T Pro HD1913 (`hotdog`)

Result: revision `r8` fixes a generation mismatch in the Qualcomm SMB charger
driver, direct-boots on hardware, programs the intended PM8150B limits, and
completes a guarded 180-second charging trace. Long-duration runtime stability,
cable transitions, thermal policy, and suspend remain unvalidated.

## Problem found in r7

Revision `r7` enabled the existing PM8150B fuel-gauge and SMB5 charger nodes.
The supplies registered, but a direct debugfs register audit showed that the
driver was applying SMB2 conversion factors to SMB5 hardware:

| Register | Raw value | Actual PM8150B setting |
|---|---:|---:|
| `FLOAT_VOLTAGE_CFG` (`0x1070`) | `0x7d` | 4.85 V |
| `FAST_CHARGE_CURRENT_CFG` (`0x1061`) | `0x4e` | 3.90 A |
| `USBIN_CURRENT_LIMIT_CFG` (`0x1370`) | `0x14` | 1.00 A |

The fuel gauge reached 4,527,000 uV. USB input was immediately suspended
through the charger power-supply interface before further development. The
`r7` power configuration must not be used as an accepted charging baseline.

## Source correction

`0020-power-supply-qcom-smbx-use-generation-specific-limits.patch` adds
per-generation float-voltage, fast-charge-current, and input-current ranges to
the driver match data. The values were checked against the Qualcomm downstream
PM8150B, PM7250B/PMI632, and SMB2 implementations.

For PM8150B, revision `r8` now uses:

| Parameter | Encoding | Programmed limit |
|---|---|---:|
| Float voltage | 3.60 V base, 10 mV steps | 4.40 V |
| Fast-charge current | 50 mA steps | 1.50 A |
| USB input current | 50 mA steps | 500 mA |

SMB5 probe first suspends USB input and disables charging. It applies the
battery limits, initializes the remaining driver state, then enables charging
and USB input as its final actions. Any error before that point leaves the
input path suspended. The patch also fixes the overvoltage helper to test the
register value rather than the register address.

The patch passed `checkpatch.pl --strict` with zero errors and zero warnings.
The package validator checks the generation-specific source contract and fails
the build if the guarded ordering or selected ranges change. The patch SHA512
is:

```text
7b8777a11826e89e578c1141ad7d8c78a096d81ffebcf65ff79d966d53c803e963ed9e2df77d7064ebbeeae7281738c44744de535f25133a8ed12080459a307a
```

## Reproducible build

Two strict pmbootstrap builds started from reset buildroots and produced APKs
that compare equal byte-for-byte:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r8.apk` | 25,536,679 bytes | `668c87bfb2e5f25b7e910e4c471414c85053d33e2fd52d9041136716a5967650` |
| `boot/vmlinuz` | 27,572,232 bytes | `4bdf4c4c1e2fd8ffaa5428695ab51bbf7a9a7364eba84eb632250d9436575446` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 139,672 bytes | `17e7dabb69f8376cbd294e82b01fcbd797d7bcc05d5f5a31b42939bf86ddad19` |

The DTB is byte-identical to `r7`; only the charger driver changes. The kernel
retains the validated `0x80000` ARM64 load offset and `0x1ad0000` Image window.

The package kernel, unchanged DTB, and accepted initramfs were assembled into a
96 MiB AVB image with SHA256
`32d5e2a4cea4d31c4200dbf6da82abfc7e2a25b717f3a3c7a017a688c3cf6376`.
The complete image was written to `/dev/sde38` (`boot_b`) from the running `r7`
system and read back with the same hash before reboot.

## Hardware result

The new boot ID was `44e65247-e824-4213-afff-6e1ec594dfb4`. The kernel reported
build `#9-oneplus-hotdog-mainline616`, returned USB networking and SSH, and
logged:

```text
qcom-smbx-charger ... Generation SMB5
qcom-smbx-charger ... charge limits: float=4400000 uV fast=1500000 uA input=500000 uA
```

Root-only debugfs reads confirmed the physical PM8150B register values before
and after the observation period:

| Register | Raw value | Result |
|---|---:|---|
| `CHARGING_ENABLE_CMD` (`0x1042`) | `0x01` | charging enabled |
| `FAST_CHARGE_CURRENT_CFG` (`0x1061`) | `0x1e` | 1.50 A |
| `FLOAT_VOLTAGE_CFG` (`0x1070`) | `0x50` | 4.40 V |
| `ICL_STATUS` (`0x1107`) | `0x0a` | 500 mA |
| `USBIN_CMD_IL` (`0x1340`) | `0x00` | USB input active |
| `USBIN_CURRENT_LIMIT_CFG` (`0x1370`) | `0x0a` | 500 mA |

A 180-second trace sampled both power supplies every three seconds under a
4,420,000 uV abort guard:

| Measurement | Minimum | Maximum |
|---|---:|---:|
| Battery voltage | 4,407,459 uV | 4,408,680 uV |
| Battery current | -121,581 uA | -90,820 uA |
| USB input voltage | 4,893,424 uV | 4,942,208 uV |
| USB input current | 17,582 uA | 44,052 uA |

All 61 samples reported `Charging` for both supplies, 99 percent battery, a
24.0 C battery temperature, and a 500,000 uA USB input limit. The trace exited
with `POWER_VALIDATION_PASS`; no sample crossed the guard.

## Runtime caveat and remaining work

After the completed trace, USB and SSH disappeared and the handset exposed
Qualcomm `05c6:900e`. A read-only Sahara capture recovered the complete 4 MiB
ramoops reservation. The original scanner assumed 256 KiB zones and skipped
the two populated 4 KiB zones at the end of the reservation. Geometry-aware
extraction recovered a 4,084-byte kernel-console ring and an 814-byte pmsg
record. The console ends at 17.382699 seconds with normal deferred-probe
messages; it contains no panic, oops, charger fault, UFS error, or USB fault.
No reset was sent from `900e`. The bounded memory image has SHA256
`88378af94ba17724e9fa8d0c8479f1a2b1f016bba78db7e9219c7d5079dfc8cc`.

This later transition does not change the measured PMIC programming or the
completed charging trace, but it prevents treating `r8` as a long-duration
stability result.

A second direct `r8` boot, ID `7c7e99b7-8714-4836-9ec2-e23b77732a08`, then
ran the persistent runtime monitor for 600 seconds. It wrote one compact record
per second to ramoops pmsg while also returning the records over SSH. All 601
samples completed, spanning 98.24 through 716.96 seconds of system uptime:

| Runtime signal | Observed result |
|---|---|
| UFS runtime state | 352 active, 245 suspended, 4 suspending |
| `/dev/sda` and `/dev/loop0p2` | present in all 601 samples |
| DWC3 UDC | `a600000.usb:configured` in all 601 samples |
| USB input limit | 500,000 uA in all 601 samples |
| Battery status | `Charging` in all 601 samples |
| Battery voltage | 4,406,971 to 4,408,191 uV |
| Battery current | -97,656 to -50,292 uA |

No USB transition or `900e` identity occurred. The successful second run proves
that the earlier transition is not a deterministic fixed-time failure and
found no gradual loss of UFS, the mounted root, or the USB gadget. It does not
erase the first failure: the next comparison should reduce host traffic while
retaining pmsg breadcrumbs, then isolate UFS and DWC3 runtime power management
before covering unplug/replug, charge termination, low state of charge,
thermal limits, and suspend/resume.
