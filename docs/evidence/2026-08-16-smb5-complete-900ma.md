# Complete-system SMB5 900 mA validation

Date: 2026-08-16

## Status

The complete postmarketOS Plasma/OpenRC image boots directly and sustains a
900 mA SuperSpeed USB input limit. A guarded 180-second run completed with the
charger online, status `Charging`, health `Good`, and a rising battery voltage.

This is an integration result built on top of the exact upstream-oriented SMB5
v3 tree. The USB3 current selection, AICL rerun, writable input-current limit,
DWC3 power-supply link, and 900 mA gadget configuration are separate follow-up
changes. They are not part of the mailed SMB5 v3 series.

## Build identity

- kernel source commit: `85c6a4ee2f9fc59e8924aa87505a1a796a22fc18`;
- kernel source tree: `f6b7912af50e0c30b45d85531cb049909f2752b5`;
- runtime: `6.16.0-sm8150 #179-smb5-dwc3-icl-900ma-v1`;
- kernel SHA-256:
  `9871837071bfb350d380e730f719c88b5cb45f3dd7928dc9f5b080b6b4747bc9`;
- AVB boot image SHA-256:
  `1f4fb9f5b2d56faa0b9581774cdda89241c363b2f643bbdc78659247cb67d8a9`;
- complete root image SHA-256:
  `da14ec85cdde39336baf84bacbf33b11e8aa609c3e527b324cb9e3e7f0113324`;
- boot ID: `383f0878-01a6-43a4-a210-b4aaa8c3d733`.

The root image contains the full Alpha Plasma package set, 765 modules with
matching `6.16.0-sm8150` vermagic, and the normal OpenRC services. Plasma,
KWin, NetworkManager, SSH, touch input, and the USB gadget were present after
boot.

## Charging result

The host decoded the SuperSpeed configuration as 896 mA, the USB 3 encoding
for the gadget's 900 mA request. The charger exposed both `current_max` and
`input_current_limit` as 900000 uA.

The 180-second run collected 19 samples:

- all samples remained online, `Charging`, and `Good`;
- the input limit stayed at 900000 uA;
- average measured input current was 876614 uA;
- battery voltage rose from 4,138,000 to 4,146,000 uV;
- battery temperature rose from 28.7 to 30.1 C;
- no low-current or safety guard fired.

The boot log contains the expected `Generation SMB5` probe and charge-limit
report. No warning, error, oops, or lockdep report was scoped to SMB5. Existing
board bring-up warnings from unrelated subsystems remain visible and are not
reclassified by this test.

## Reproducibility

The mainline616 package now carries the five integration patches explicitly
and selects `CONFIG_USB_GADGET_VBUS_DRAW=900`. Replaying those package patches
from the pre-integration parent produced byte-identical `qcom_smbx.c`, Hotdog
DT source, and gadget Kconfig files to the validated source tree.

The DWC3 `usb-psy-name` property used by this integration is not a documented
upstream binding. Upstream work must keep it and the remaining 900 mA policy
changes separate from the already validated SMB5 v3 series until each interface
has an accepted generic design.

## Evidence paths

Raw evidence is retained under
`logs/2026-08-16-smb5-complete-v16-900ma/`, notably:

- `27-dmesg-full.txt` and `27b-dmesg-smb5-extract.txt`;
- `28-charge-180s.tsv` and `28-charge-180s-summary.txt`;
- `30-checkpatch-*.txt` and `32-v3-qcom-smbx-w1.log`;
- the build, image, flash, readback, boot, and package manifests in the same
  directory.
