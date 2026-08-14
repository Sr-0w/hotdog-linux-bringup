# USB input-current investigation

## Status

Hardware-tested on 2026-08-14 using the complete postmarketOS / Plasma Mobile
root filesystem. The same computer port and cable were used for both kernels.

This evidence does not establish that 500 mA is adequate. Both kernels
programmed a 500 mA USB input limit, and the downstream control lost reported
battery capacity under the complete-system workload.

## Mainline SMB5 v3 baseline

- Kernel: `6.16.0-sm8150 #177-smb5-v3-ba989060`
- `boot_b` SHA-256:
  `7ac65591ecda2adf00efb3a35134ef6872a0cf044c73698a1b6785532ecf6e6d`
- `dtbo_b` SHA-256:
  `d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd`
- USB type: SDP
- SMB5 `current_max`: 500000 uA
- Measured USB input current: approximately 478 mA

The TCPM power supply did not provide a usable current limit. The charger
therefore remained at its conservative 500 mA board limit.

## Downstream control

The control used the known bootable downstream kernel with the stock DTBO,
while retaining the same postmarketOS userspace and cable:

- Kernel: `4.14.357-openela-perf #6-postmarketOS`
- Downstream `boot_b` SHA-256:
  `28c08d1668955a791f24d0d392658b06d1e452921f04be60c44278d27014966b`
- Stock `dtbo_b` SHA-256:
  `95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672`
- Boot ID: `acdc55ee-79e9-4b80-aa87-b13781e86115`
- USB type: `USB`
- Type-C mode: `Source attached (default current)`
- `usb/current_max`: 500000 uA
- `usb/hw_current_max`: 500000 uA
- `usb/input_current_settled`: 500000 uA
- `main/current_max`: 500000 uA
- Measured USB input current: 475-478 mA

The host-visible SuperSpeed gadget descriptor requested 896 mA. An early-boot
capture, started before networking, established the complete sequence:

- at 4.446 s, APSD classified the source as SDP and the Oplus policy requested
  500 mA;
- at 4.590 s, DWC3 propagated the pre-configuration 100 mA limit;
- at 4.917 s, after `USB_STATE=CONFIGURED`, DWC3 propagated 900 mA without a
  `power_supply_set_property()` error;
- the charger nevertheless remained programmed for 500 mA.

The downstream source explains the mismatch. The built charger implementation
is `drivers/power/oplus/charger_ic/oplus_battery_msm8150Q.c`, not the disabled
`drivers/power/supply/qcom/qpnp-smb5.c` object. Its Oplus-specific branch in
`set_sdp_current()` clears `CFG_USB3P0_SEL_BIT` for every request above 150 mA,
thereby mapping both 500 mA and 900 mA requests to the USB2 500 mA hardware
mode. The relevant downstream source identity is commit
`6ecfabed032b68a8f0a0fd003cf5fbfb6d672acb`, tree
`eff960af12c7f7f4770320805522b9a61b1f1052`.

Filtered SPMI tracing agrees with the source: enumeration changed
`USBIN_ICL_OPTIONS_REG` (`0x1366`) and the ICL override registers, but did not
program `USBIN_CURRENT_LIMIT_CFG_REG` (`0x1370`). The resulting USB input
current stayed at approximately 476 mA.

During a passive 180-second sample window, with no power-supply writes:

- all 37 samples retained the 500000 uA limit;
- reported battery capacity fell from 43% to 41%;
- BMS capacity fell from 45% to 44%;
- BMS current remained positive at approximately 0.57-0.73 A;
- the vendor battery supply continued to report `Charging` and
  `input_current_limited=1`.

The capacity trend and input-current-limited flag show that the 500 mA input
did not cover the active system load. The sign convention of the downstream
BMS current still needs to be tied to the exact gauge implementation before
using that property alone as a charge/discharge verdict.

## Interpretation

This is a kernel-plus-DTBO control, not a complete OxygenOS Android control.
It establishes the downstream kernel's behavior with the complete
postmarketOS image and the same PC port and cable, but it does not establish
the policy selected by stock Android userspace or by a proprietary VOOC
charger.

The stock DT describes source-specific policy limits of 500 mA for USB SDP,
1500 mA for CDP, 2000 mA for DCP, and 3000 mA for PD. It also provides a
1.8 A generic USB ICL hardware cap. These are policy ceilings, not permission
to draw that current before the corresponding source capability is known.

The mainline implementation should keep detection ownership separated:

1. BC1.2 determines SDP, CDP or DCP capability.
2. USB gadget enumeration reports the configured SDP current to the charger.
3. TCPM reports Type-C Rp and negotiated PD limits.
4. SMB5 clamps the selected source limit to board and hardware safety limits,
   then runs AICL before accepting the operating point.

The charger must not depend on TCPM in a way that creates a device-link cycle.
The previously tested `power-supplies` dependency did so and is not a viable
upstream design.

## Complete-system 900 mA validation

A follow-up kernel candidate connected the active DWC3 gadget to the SMB5
power supply for test purposes and exposed `INPUT_CURRENT_LIMIT`. This is a
test-only integration: the `usb-psy-name` property used by that candidate is
not a documented upstream binding and is not part of the proposed SMB5
series.

The complete Plasma Mobile system initially remained at 100 mA because its
configfs gadget configuration retained the kernel default `MaxPower=2`.
Changing `configs/c.1/MaxPower` to 900 and reauthorizing the host device caused
DWC3 to publish 900 mA and SMB5 to program the same limit:

- kernel: `6.16.0-sm8150 #178-smb5-dwc3-icl-v1`;
- kernel commit: `7f22ba7c6f3b38542683a91c5931f95a064f3a90`;
- kernel tree: `d6d647860bb627a5ee97040a1764df8c26b2aada`;
- partition image SHA-256:
  `ad5e2337aea89f7b61c9ecdc28e45b07cf2dd287a9c80f27c04fbfc97dfc4155`;
- gadget speed: SuperSpeed;
- gadget and charger limits: 900000 uA;
- measured input current: approximately 876-877 mA;
- measured input voltage: approximately 4.62 V.

A guarded 180-second run passed first. A subsequent 600-second run completed
all 61 samples with `online=1`, `status=Charging`, `health=Good`, an input
limit of 900000 uA and a maximum reported thermal-zone temperature below
41 degrees C. The OLED remained in `FB_BLANK_POWERDOWN` (`fb0/blank=4`) for
the entire long run while USB networking and SSH remained available. The
fuel gauge reported positive charging current around 0.74 A during the run.

This isolates the complete-system policy gap from the SMB5 register logic.
The generic postmarketOS fix is to let a device specify a configfs
`MaxPower` value before binding the UDC. Hotdog sets 900 mA; the composite
gadget core still caps the request to 500 mA at USB 2 speed and 900 mA at
SuperSpeed.

The first persistence image (`maxpower-v2`) accidentally replaced the modern
`postmarketos-initramfs 3.12.0-r0` helper with the historical 3.4.6 helper
from the old local pmaports checkout. It enumerated NCM but did not configure
the phone-side IP address and is rejected. The corrected `maxpower-v3` image
starts from the exact validated 3.12.0 ramdisk and adds only the optional
`MaxPower` write plus the Hotdog value. Its partition image SHA-256 is
`8d0ed0705b8377cee9cfe1c58b2e0a3ead2ac84d9632bbe274cbe04c3d24d552`;
hardware validation is pending.

## Raw evidence

Raw logs are retained locally under:

`logs/downstream414-stockdtbo-control-2026-08-14-212457/`

The deeper boot, source and SPMI capture is retained under:

`logs/downstream414-stockdtbo-deep-dive-2026-08-14-214416/`

Important files include:

- `downstream-baseline.txt`
- `downstream-detailed-power.txt`
- `passive-180s.tsv`
- `dmesg-before-180s.txt`
- `dmesg-after-180s.txt`
- `mainline-upload-hashes.txt`
- `mainline-restore-readback.txt`
- `mainline-restored-runtime.txt`
- `kmsg-initial-raw.log`
- `kmsg-boot-2s-to-6s.log`
- `trace-usb-host-authorized-cycle.txt`
- `downstream-source-evidence.txt`
- `deep-dive-artifact-hashes.txt`

The 900 mA follow-up is under
`logs/2026-08-14-smb5-dwc3-icl-v1/`, notably:

- `22-charge-900ma-180s.txt`;
- `23-charge-900ma-600s.txt`;
- `24-pmaports-maxpower-package-build.log`;
- `28-flash-maxpower-v2-boot-b.log`;
- `29-reboot-maxpower-v2-monitor.log`.

The complete raw logs are intentionally excluded from Git because they may
contain device-specific data.
