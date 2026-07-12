# Roadmap

The subsystem-by-subsystem experiments, acceptance criteria, and fallback
conditions are detailed in the [hardware enablement roadmap](hardware-roadmap.md).
The packaging and submission gates are tracked separately in the
[pmaports upstreaming plan](pmaports-upstreaming.md).

## Priority 0: reproducible mainline boot

- run D4-entry next: D3 and D3-wdt both returned after about 32 seconds, so use
  a PSCI reset in the first `primary_entry` instructions to distinguish kernel
  entry from a pre-entry bootloader timeout
- retain the hash-pinned R5 bridge as the validated rollback baseline for every
  persistent control
- after direct entry works, validate the built-in Qualcomm APSS watchdog,
  reliable software reboot, and the hotdog-only PON reboot-mode properties
- validate a direct image generated from the exact r4 package payload only
  after a direct handoff baseline exists; r4 is byte-reproducible in the tested
  pmbootstrap environment, but its direct image and hardware behavior remain
  unvalidated
- remove the downstream kexec bridge from the normal boot path
- replace the 120-second and 45-second waits with readiness checks
- restore the complete RAM map
- repair Apps SMMU registration and reattach UFS, QUP, and DWC3 clients
- restore Qualcomm ICE support for UFS

## Priority 1: local interaction

- bring up display clocks, DSI, DSC, and the Samsung panel under mainline
- keep a persistent framebuffer or DRM console after userspace starts
- enable the Samsung touch controller
- validate buttons, haptics, battery reporting, and charging

## Priority 2: connectivity

- runtime-validate the packaged Wi-Fi firmware
- enable Bluetooth
- validate USB host mode and common docks
- bring up QRTR/QMI and modem services without compromising recovery access

## Priority 3: multimedia and power

- audio routing and codecs
- suspend, resume, and idle power
- camera sensors and ISP integration
- thermal management and performance states

## Upstreaming

Before proposing changes upstream:

1. replace temporary DT property removals with correct provider descriptions
2. split device-specific changes from generic SM8150 fixes
3. test against a current upstream kernel
4. run DT schema validation
5. document regressions on other SM8150 devices
6. submit pmaports packaging independently from Linux upstream patches
