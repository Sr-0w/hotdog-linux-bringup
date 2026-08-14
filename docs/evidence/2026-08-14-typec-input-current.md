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

The USB gadget descriptor requested 896 mA at SuperSpeed, but the downstream
DWC3 driver logged `Could not get usb psy`. The enumeration result therefore
did not reach the charger power supply in this postmarketOS configuration.

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
Android's gadget userspace may establish a downstream `usb-psy` path or cast
additional votes that postmarketOS does not. The result therefore establishes
what the downstream kernel negotiates with the current complete postmarketOS
image, not every behavior of stock OxygenOS.

The mainline implementation should keep detection ownership separated:

1. BC1.2 determines SDP, CDP or DCP capability.
2. USB gadget enumeration reports the configured SDP current to the charger.
3. TCPM reports Type-C Rp and negotiated PD limits.
4. SMB5 clamps the selected source limit to board and hardware safety limits,
   then runs AICL before accepting the operating point.

The charger must not depend on TCPM in a way that creates a device-link cycle.
The previously tested `power-supplies` dependency did so and is not a viable
upstream design.

## Raw evidence

Raw logs are retained locally under:

`logs/downstream414-stockdtbo-control-2026-08-14-212457/`

Important files include:

- `downstream-baseline.txt`
- `downstream-detailed-power.txt`
- `passive-180s.tsv`
- `dmesg-before-180s.txt`
- `dmesg-after-180s.txt`
- `mainline-upload-hashes.txt`
- `mainline-restore-readback.txt`
- `mainline-restored-runtime.txt`

The complete raw logs are intentionally excluded from Git because they may
contain device-specific data.
