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
the embedded footer and boot hash. Hardware validation is pending.

## Display artifact during recovery

After repeated warm Sahara resets, the panel displayed a pale, horizontally
striped image while the phone had no usable mainline userspace and repeatedly
returned to Qualcomm memory-debug mode. No display instrumentation source had
changed at the time the artifact first appeared. It is therefore tracked as a
stale bootloader/panel scanout state across warm resets, not as mainline boot
progress or a working display path. A cold reset is required before using the
screen as evidence again.

## Next validation

1. Restore and verify R6 plus the stock DTBO after the D13 crashdump.
2. Retain D13's DTB, DTBO, initramfs, command line, Gear 3 limit, and complete
   calibration sequence.
3. Move only the attached-device reset pulse after mainline's final QCOM host
   reset and before HCE enable, then record the GPIO and controller state.
4. Capture the complete 4 MiB ramoops reservation if the candidate enters
   Qualcomm `900e`. If the device responds, verify UFS LUN discovery, the
   nested postmarketOS rootfs, and fresh SSH.
