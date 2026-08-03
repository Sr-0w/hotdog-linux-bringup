# Direct-boot native UFS investigation

Date: 2026-07-31

This note records the first direct-mainline UFS calibration experiments on the
OnePlus 7T Pro. Results from the Linux 4.14 rescue environment are kept
separate from results observed under direct Linux 6.17 boot.

## Controlled baseline

The direct candidates use the same embedded mainline DTB, filtered DTBO,
postmarketOS initramfs, command line, failure panic, and R6 rollback image.
Only the mainline kernel changes between the UFS calibration candidates.

Stable component identities used by D10 through D13:

| Component | SHA256 |
|---|---|
| Embedded mainline DTB | `040b4b50989b01dafe400436137bf73a64f3ad5e89bf4c7ddf79a19b3cfcee4c` |
| Wrapped postmarketOS initramfs | `9918d137fdbf2fc64dc6185b291eefde631becf72d1aefde7c2c6a2f4a619d4d` |
| Filtered native-UFS DTBO | `d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd` |
| Stock rollback DTBO | `95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672` |
| R6 rollback boot image | `e76c85a56cdbcc6ddd105844eb322cb854fb33b2b23077da12ff098adc8f2369` |

## Native-UFS D10: SM8150 PCS Gear 3 values

D10 adds seven PCS values found in the downstream OnePlus QMP v4 calibration
table but absent from the mainline SM8150 table. Its AVB boot image is:

`be39e7f796a101b0b5727dfd7f37970144852690d444d14c739fffe5a5e4ae9e`

The persistent crash log showed that the PHY and host both probed, but the
first UFS device-init NOP timed out:

```text
ufshcd_verify_dev_init: NOP OUT failed -11
Initialization failed with error -11
probe failed -11
```

No UFS block device appeared. The postmarketOS wrapper continued, armed its
90-second failure panic, failed to find the super partition, and entered the
expected Qualcomm memory-debug mode. This made D10 a controlled negative
result: the additional PCS values neither established the link nor regressed
the later diagnostic path.

## Downstream clock-gating check

The exact R6 downstream kernel was rebuilt at commit
`6ecfabed032b68a8f0a0fd003cf5fbfb6d672acb`. A temporary module attempted a
read-only register snapshot from the UFS host and PHY MMIO windows. The last
message recovered from RAM was:

```text
HOTDOG_R6_UFS_REGDUMP_BEGIN host=0x1d84000 phy=0x1d87000
```

The first host-register read then stopped the kernel before any value could be
printed. This demonstrates that raw out-of-driver reads are unsafe while the
UFS clock domain is gated. No UFS register or phone storage was written.

A replacement diagnostic module now obtains the live `ufs_hba`, brackets a
single controller-revision read with `ufshcd_hold()` and `ufshcd_release()`,
and avoids direct PHY reads. It is built but not yet hardware-validated.

## Native-UFS D11: bootstrap guard did not match

D11 compiled a hotdog-specific HS-G3 bootstrap limit matching the downstream
bring-up order. Its AVB boot image is:

`1d04ec69cfc06443da92eebe91f84f305d98c1e6bb77e1104a2b076b5ff2430e`

The hardware run reached Image breadcrumb stage 400/detail 986 and generated a
complete ramoops console. The log identifies kernel build `#35`, enters the
postmarketOS initramfs, and reproduces the UFS failure:

```text
ufshcd_verify_dev_init: NOP OUT failed -11
Initialization failed with error -11
probe failed -11
```

No `HOTDOG_UFS_*` message appeared. The timing also matched D10 within a few
milliseconds. The selected vendor overlay changes the runtime root identity to
`qcom,sm8150-mtp` while retaining `oplus,dtsi_no = <0x4d59>`, so
`of_machine_is_compatible("oneplus,hotdog")` was false and the D11 limit never
executed. D11 is therefore a valid hardware result, but not a test of the
intended Gear 3 bootstrap.

## Native-UFS D12: runtime identity correction

D12 recognizes either the native `oneplus,hotdog` identity or the exact
overlay-produced `qcom,sm8150-mtp` plus OnePlus `dtsi_no` identity. It keeps the
D11 bootstrap and emits `HOTDOG_UFS_HW_REVISION`, `HOTDOG_UFS_BOOTSTRAP`, and
`HOTDOG_UFS_PHY_START` messages. Its AVB boot image is:

`595b8ac4ad1d3e02726d6ecc9778347a1d656767afce23f680bce01d36d01601`

D12 was hardware-validated on 2026-08-01. R6 was first restored with the pinned
boot and stock-DTBO hashes, reached SSH as `4.14.357-openela-perf`, and handed
off to the D12 AVB image through the guarded slot-B transaction. The recovered
console proves that the corrected runtime guard matched:

```text
HOTDOG_UFS_HW_REVISION=4.1.0
HOTDOG_UFS_BOOTSTRAP controller_max_gear=4 host_max_gear=3
HOTDOG_UFS_PHY_START hw=4.1.0 gear=3 rate=B
```

The device still did not answer the first initialization request:

```text
ufshcd_verify_dev_init: NOP OUT failed -11
Initialization failed with error -11
probe with driver ufshcd-qcom failed with error -11
```

The failure-only panic fired at `91.599726` seconds and Qualcomm `900e` became
visible about 140 seconds after the bootloader reboot. The bounded physical
capture SHA256 is
`ebc156e2617b1cef33c226b937d819f79dab4fbbc0251173e37392334d0bb0ef`;
the extracted ramoops console SHA256 is
`d6890d82294a1209b40521b238ad4a517611a2fb560fb097f373ec888ec70a70`.
D12 therefore proves that limiting the initial negotiation to HS-G3 is applied
but is insufficient on its own. This unblocks the D13 lane-calibration test.

## Native-UFS D13: revision-2 Gear 3 lane calibration

The downstream QMP v4 driver applies an additional table for revision-2
controllers operating at Gear 3. D13 represents those values as a native
mainline `UFS_HS_G3` overlay:

| Register group | Values |
|---|---|
| TX lane mode | `TX_LANE_MODE_1 = 0x35` |
| RX clock recovery | `SO_SATURATION_AND_ENABLE = 0x5a`, `FO_GAIN = 0x0e` |
| RX mode 00 | `LOW = 0x6d`, `HIGH = 0x6d`, `HIGH2 = 0xed`, `HIGH4 = 0x3c` |

The mainline QMP lane helper applies the same overlay to both physical lanes.
D13 retains D10's PCS values, D11's Gear 3 bootstrap, and D12's runtime trace.
Its AVB boot image is:

`1efe20d49953d32409091db1ef2b461236dd5f88f22fc524cc5b154dc9a6d7d7`

D13 was reproduced byte-for-byte in two independent package builds and passed
AVB verification. It was hardware-validated on 2026-08-01 after a fresh R6
boot with ID `775595a0-3189-404c-b8ab-cbe796fb005e`. The recovered console
identifies kernel build `#37` and proves that the D12 guard remained active:

```text
HOTDOG_UFS_HW_REVISION=4.1.0
HOTDOG_UFS_BOOTSTRAP controller_max_gear=4 host_max_gear=3
HOTDOG_UFS_PHY_START hw=4.1.0 gear=3 rate=B
ufshcd_verify_dev_init: NOP OUT failed -11
```

The first NOP failed at `0.928083` seconds, compared with `0.932620` seconds
for D12. Both extracted consoles contain exactly 57,303 bytes, and D13 reached
the same controlled panic at `91.590180` seconds. The bounded physical capture
SHA256 is
`43d0bbdd936c06b34b9fc98c3a1c8ea68698bdb2e4a4834c8bdcd08d92f47405`;
the extracted console SHA256 is
`1f6540f76dd179b7f962c9d0419fcf1379d72bf3490a0025c7b60a65d05a7ac2`.
D13 therefore proves that the revision-2 Gear 3 lane calibration alone does
not establish communication with the UFS device.

## Native-UFS D14: device reset after final host reset

The generic mainline UFS core pulses the attached-device reset before calling
the QCOM HCE preparation hook. That hook subsequently performs another core
reset as part of `ufs_qcom_power_up_sequence()`. The working downstream path
performs its full core reset before pulsing the attached device. D14 retains
D13 and adds a second 10-to-15-microsecond device-reset pulse after mainline's
last host reset and PHY calibration, immediately before HCE enable. It records
`REG_UFS_CFG1`, controller status, and the reset-GPIO state before and after the
pulse.

The D14 AVB image is:

`7374d7cb3d74a0fe59e9fc560217451d09cd0f4fc2169a5dcd242bf574356737`

Two independent package runs reproduced this image byte-for-byte. Its DTB and
wrapped postmarketOS initramfs remain identical to D13, and `avbtool` verifies
the embedded footer and boot hash.

D14 was hardware-validated on 2026-08-01 after a fresh R6 boot with ID
`7197faff-8f25-49c3-8305-d0ef5543dcb6`. The direct image entered Qualcomm
`900e`; the complete 4 MiB ramoops reservation and 57,524-byte console were
recovered automatically. The console identifies kernel build `#38` and records:

```text
HOTDOG_UFS_HW_REVISION=4.1.0
HOTDOG_UFS_BOOTSTRAP controller_max_gear=4 host_max_gear=3
HOTDOG_UFS_PHY_START hw=4.1.0 gear=3 rate=B
HOTDOG_UFS_AFTER_HOST_RESET begin cfg1=0x1c00052c hcs=0x8 reset=1
HOTDOG_UFS_AFTER_HOST_RESET done cfg1=0x1c00052c hcs=0x8 reset=1
ufshcd_verify_dev_init: NOP OUT failed -11
```

The first NOP failed at `0.939149` seconds and the controlled panic occurred at
`91.601235` seconds. The bounded physical capture SHA256 is
`0a62f29d39c6be22438ba72cc7f865fdda893b9657d741df9bee6e2292cd247e`;
the extracted console SHA256 is
`132cbe54d2444e6fda7490cf07f3e02dac6f7fa60ce24f4506ad1bb435b411b4`.

The marker proves that the new code path executed, but its `reset=1` fields do
not measure the physical line. SM8150 GPIO 175 is the dedicated `UFS_RESET`
pad: its pinctrl description has output bit 0 but `in_bit = -1`. The generic
GPIO read path therefore cannot sample this pad and, after active-low inversion,
returns `1` regardless of its output latch. D14 proves that this attempted
ordering change is insufficient; a future trace can read the dedicated output
latch directly if electrical sequencing remains in question.

## Native-UFS D15: downstream PCS software-reset order

The working downstream 4.14 QMP-v4 PHY asserts the PCS software reset before
writing its calibration table, clears PCS reset after calibration, and only
then deasserts the host UFS PHY reset. Mainline writes the table while PCS reset
is not explicitly asserted and clears PCS reset only after the host reset has
already been released. D15 retains D14 and changes only this PHY sequence for
the SM8150 configuration. It logs the PCS reset register before assertion,
after calibration and deassertion, and after the host reset is released.

The D15 AVB image is:

`6737a8099b178b63587c639c0101096b27b87aeb010c0de55bd50e218f5ca405`

Its kernel Image SHA256 is
`902c0e8a8ac5a7491d4234fd04bc37ae549ab5dc93b50f6317656c70376d4f49`.
Two independent package runs reproduced the complete image byte-for-byte. The
DTB, wrapped initramfs, and command line remain identical to D14, and AVB
verification succeeds.

D15 was hardware-validated on 2026-08-01 after a verified R6 boot with ID
`659cfe23-58fb-453c-9ee8-9d7aed49be24`. The direct image entered Qualcomm
`900e`; the bounded automatic capture recovered the complete 4 MiB diagnostic
window and a 57,814-byte console. The console identifies kernel build `#39`
and records:

```text
HOTDOG_UFS_HW_REVISION=4.1.0
HOTDOG_UFS_BOOTSTRAP controller_max_gear=4 host_max_gear=3
HOTDOG_UFS_PHY_START hw=4.1.0 gear=3 rate=B
HOTDOG_UFS_PCS_SW_RESET before=0x1 asserted=0x1
HOTDOG_UFS_PCS_SW_RESET calibrated=0x1 deasserted=0x0
HOTDOG_UFS_PCS_SW_RESET host_deasserted=0x0
HOTDOG_UFS_AFTER_HOST_RESET begin cfg1=0x1c00052c hcs=0x8 reset=1
HOTDOG_UFS_AFTER_HOST_RESET done cfg1=0x1c00052c hcs=0x8 reset=1
ufshcd_verify_dev_init: NOP OUT failed -11
```

PCS was already asserted on entry, remained asserted while every calibration
table was written, was cleared before the host reset was released, and stayed
clear afterwards. The first NOP failed at `0.939979` seconds and the controlled
panic occurred at `91.613433` seconds. The physical capture SHA256 is
`634d9031cfeabdf3aabd599617fb410a530efe9f786ed494a59b3e236054c9f9`;
the extracted console SHA256 is
`5ad8f57b187afad6764d3a0235104b4d9208e9416ed928b43725eff1a93721a8`.
D15 therefore reproduces the downstream PCS reset order and proves that this
ordering alone does not establish communication with the device.

An offline comparison after D15 found that the effective direct-boot tree is
unchanged from the mainline OnePlus tree for the UFS controller, QMP PHY, all
five referenced regulators, GCC, RPMh clocks, and TLMM. The downstream v2
Gear 3 PHY values now also match the D15 mainline tables.

The planned R6 hold/release measurement was attempted on 2026-08-01 and proved
unsafe. `ufshcd_hold()` tried to leave a clock-gated hibern8 state, timed out,
entered broken vendor error recovery, and left module loading blocked in
`flush_work()`. The normal boot log already records the working Gear 4, two-lane
Fast Rate B state, while the timeout handler captured host registers and clock
rates at the failure boundary. The exact incident is recorded in
[the R6 UFS live-probe evidence](2026-08-01-r6-ufs-live-probe.md). No further
live register or DME probe will be made from a healthy R6 session.

## External hotdog mainline comparison

The hotdog branch of
[`ClearStaff/linux-sm8150-mainline-hotdog`](https://github.com/ClearStaff/linux-sm8150-mainline-hotdog)
was inspected at commit `403b56c33e2ccdda25d90378970a5e5b928dee19`.
Its OnePlus 7T Pro DTS enables the same UFS controller, QMP PHY, and PM8150
rails as the direct candidate, but it does not describe GPIO175 as an attached
device reset. Its `vreg_l5a_0p8` PHY supply and mainline's
`vdda_ufs_2ln_core_1` label both resolve to PM8150 LDO5 at 880 mV, so that
spelling is not an electrical difference.

This leaves the missing `reset-gpios` property as the first concrete
hotdog-specific difference in the external tree. The prepared D16 image keeps
the D13 kernel, initramfs, and filtered DTBO byte-identical, while the embedded
DTB removes `/soc@0/ufshc@1d84000/reset-gpios`. The DTB transformer verifies
the complete decompiled trees differ by only that property. The hardware test
variant additionally removes `hotdog_rescue_watchdog_sec=120` from the command
line. This is an operational policy change, not a UFS configuration change: it
prevents the initramfs supervisor from rebooting a stalled candidate. It keeps
`panic=0`, which holds a kernel panic for diagnosis. The passive D16 AVB SHA256
is `971ac2a5cf2dfb0ef55911eb20a05e5c98314e8ddc3b4bde4718b3aa664b70b7`;
two independent package runs reproduced it byte-for-byte.

## Native-UFS D16: passive no-device-reset result

D16 was launched from verified R6 boot
`3b9b4950-2808-46a6-81c9-9feaf723f81a` on 2026-08-02. The transaction flashed
the native-UFS filtered DTBO SHA256
`d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd`
and the D16 image, selected slot B, and rebooted at 01:59:34. The 180-second
observation found no Fastboot identity, USB gadget, or postmarketOS SSH. No
candidate watchdog, Sahara reset, or other software reset was sent.

The phone remained unavailable until a manual reset exposed Fastboot at 10:48.
The pre-armed restore transaction then wrote the pinned stock DTBO SHA256
`95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672`
and exact R6 boot SHA256
`e76c85a56cdbcc6ddd105844eb322cb854fb33b2b23077da12ff098adc8f2369`,
selected slot B, and deliberately left the phone in Fastboot. R6 subsequently
booted normally and exposed USB networking and SSH. Its ramoops backend attached
at `0xa9800000`, but `/sys/fs/pstore` was empty. The D16 transaction log SHA256
is `b3f50a82b302c260ff4b3fbe24d97fef3cd67a9c273de5e0d7174fb756bbcbf4`;
the restore log SHA256 is
`c5c8f56f8f51304b0e2ea4d8a50aee169a42ec779e78b1f59b3cf5cc740b8952`;
and the empty-pstore report SHA256 is
`7cf1b9d88f33b1cc8176ef312be73666b3a1094996b5ef812501c4f2eec714a9`.

D16 therefore proves that removing only `reset-gpios` is not sufficient for a
usable direct boot. Because the passive run produced no recoverable console, it
does not prove whether the first UFS NOP still failed. A complete comparison
also found that ClearStaff's 663-line standalone hotdog DTS differs globally
from this project's OnePlus-common DTS plus filtered vendor DTBO. The next
control must reproduce the complete external kernel and DTS rather than borrow
one UFS property from it.

## Display artifact during recovery

After repeated warm Sahara resets, the panel displayed a pale, horizontally
striped image while the phone had no usable mainline userspace and repeatedly
returned to Qualcomm memory-debug mode. No display instrumentation source had
changed at the time the artifact first appeared. It is therefore tracked as a
stale bootloader/panel scanout state across warm resets, not as mainline boot
progress or a working display path. A cold reset is required before using the
screen as evidence again. Subsequent direct-UFS tests use read-only `900e`
inspection and manual recovery instead of protocol-level Sahara resets.

## Next validation

1. Keep the recovered R6 boot and its normal log as the downstream reference;
   do not touch the live controller again.
2. Build the exact ClearStaff `403b56c33e2c` kernel and standalone hotdog DTS
   without local UFS experiments.
3. Pair that complete external baseline with a minimal, explicitly verified
   DTBO so retained Android fragments cannot rewrite unrelated shared hardware.
4. Package it with the known postmarketOS initramfs, validate every component
   identity offline, and hardware-test it without candidate reset automation.
5. If the exact external baseline still fails, add boot-time visual and
   persistent diagnostics before changing another UFS electrical parameter.
