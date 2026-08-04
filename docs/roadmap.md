# Roadmap

The subsystem-by-subsystem experiments, acceptance criteria, and fallback
conditions are detailed in the [hardware enablement roadmap](hardware-roadmap.md).
The packaging and submission gates are tracked separately in the
[pmaports upstreaming plan](pmaports-upstreaming.md).

The accepted long-lived hardware baseline is now the reproducible 6.16 `r13`
package. Its
exact source-built kernel and DTB direct-boot with writable rootfs, USB SSH,
S6SY761 multitouch, an Adreno 640 render node that completes Turnip Vulkan
workloads, corrected conservative SMB5 limits, registered Power plus volume-key
inputs, correct 60 Hz KMS scanout, and a usable Plasma Mobile session.

## Priority 0: reproducible mainline boot

- keep D6 as a timing-sensitive negative control; it exposes all UFS LUNs,
  NCM, and ACM, but a repeat cycle entered Qualcomm `900e` crashdump mode
- prearm the verified ACM bootloader fallback before every initramfs
  continuation so a failed rootfs transition remains remotely recoverable
- rerun the `super` loop hook after late UFS discovery and require both pinned
  postmarketOS filesystem UUIDs before leaving the ACM shell
- use hardware-validated D7 for the next direct-mainline pairing; unchanged R5
  produced fresh SSH and exact `boot_b`/`dtbo_b` readback with this overlay
- retain the hash-pinned R6 bridge plus stock DTBO as the validated rollback
  baseline; hardware readback proves the watchdog-disabled command line and
  both partition images
- retain D12 as proof that the hotdog runtime identity guard selects HS-G3
  Rate B on controller revision 4.1.0, and D13 as proof that the downstream
  revision-2 Gear 3 lane values still leave the first UFS NOP at `-11`
- retain D14 as proof that requesting a second UFS device reset after the final
  host reset is insufficient; its generic GPIO readback is invalid for the
  dedicated output-only `UFS_RESET` pad, so trace the output latch directly if
  reset sequencing needs further investigation
- retain D15 as proof that the downstream PCS software-reset order still leaves
  the first UFS NOP at `-11`
- capture a clock-safe host, QMP, and local UniPro reference from working R6,
  then test the passive D16 image whose DTB removes only GPIO175
  `reset-gpios`, matching the external ClearStaff hotdog DTS policy; the test
  command line deliberately omits the rescue watchdog so a failure remains
  observable until manual recovery
- after direct entry works, validate the built-in Qualcomm APSS watchdog,
  reliable software reboot, and the hotdog-only PON reboot-mode properties
- remove the downstream kexec bridge from the normal boot path
- replace the 120-second and 45-second waits with readiness checks
- restore the complete RAM map
- repair Apps SMMU registration and reattach UFS, QUP, and DWC3 clients
- restore Qualcomm ICE support for UFS

## Priority 1: local interaction

- preserve the working native display clocks, DSI, DSC, Samsung panel, and
  persistent framebuffer console while the userspace package is finalized
- reproduce the validated Plasma Mobile package selection in a fresh image and
  run repeated direct boots into the graphical session
- validate 90 Hz separately from the accepted 60 Hz mode, then validate frame
  pacing, blank/unblank, and suspend/resume
- validate S6SY761 suspend/resume and touch wake after the successful Weston
  and Plasma Mobile orientation tests
- capture physical volume-key events, then validate wake behavior
- validate haptics and extend the working basic battery/charging support to
  cable transitions, termination, thermal limits, and suspend

## Priority 2: connectivity

- validate Wi-Fi association, stable MAC handling, and sustained traffic
- validate the prepared `r15` direct Bluetooth firmware selection, then
  pairing and sustained connections
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
