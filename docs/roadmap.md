# Roadmap

## Project goal

The goal has two halves, and both are required.

**Publishable in postmarketOS.** The device must be submittable as a normal
pmaports device: built from a shared, upstreamable kernel package rather than
the device-specific fork used during bring-up, without laboratory-only
deployment steps, with device-tree changes that are correct descriptions rather
than temporary removals, and with an honest support matrix.

**Complete hardware support.** Every peripheral the handset has should work,
not merely enough of them to clear a device category. USB host mode, external
display over the Type-C dock, cameras, sensors and telephony are all in scope.

Neither half is subordinate to the other. Submission gates are not an excuse to
stop enabling hardware, and hardware work is not an excuse to leave the packages
unsubmittable. An earlier framing of this project as a dockable Gentoo desktop
is dropped, but the dock hardware itself remains a real target.

The submission gates are tracked in the
[pmaports upstreaming plan](pmaports-upstreaming.md). The subsystem-by-subsystem
experiments, acceptance criteria, and fallback conditions are detailed in the
[hardware enablement roadmap](hardware-roadmap.md).

The current hardware candidate is the 6.16 `r108` package, built on the
reproducible `r22` memory-reservation baseline. The
accepted 6.16 stack direct-boots with writable rootfs, USB SSH, S6SY761
multitouch, an Adreno 640 render node that completes Turnip Vulkan workloads,
corrected conservative SMB5 limits, registered Power plus volume-key inputs,
dynamic stock 60/90 Hz KMS modes, Wi-Fi association, Bluetooth HID, and a
usable Plasma Mobile session. The isolated `r22` DT hardware test fixes the
reproducible large buffered-import crash by completing the stock HD1913 memory
reservation union. The exact source-built `r22` kernel, DTB, modules, and
standard `boot-deploy` image also direct-booted and passed a synchronized 6 GiB
buffered-write soak. A fresh image assembled only from the public pmaports tree
is installed in `super` with complete SHA-256 readback, and its matching
deterministic AVB image direct-boots from `boot_b` into Plasma Mobile. Repeated
boots have kept the clean image healthy, including a successful Discover
installation and smooth interactive 0 A.D. gameplay. Device package `3-r7`
closes the separate manual AVB-wrapping step: a full clean 1,524-package build
generated the verified fixed-size image twice with identical bytes. Automatic
`polkit-elogind` provider selection and eventual generic `boot-deploy` support
for the hotdog footer contract are the remaining packaging gates. Revision
`r20` remains the binary control.

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
  and the hotdog-only PON reboot-mode properties; reliable normal software
  reboot is hardware-validated on `r108`
- remove the downstream kexec bridge from the normal boot path
- replace the 120-second and 45-second waits with readiness checks
- restore the complete RAM map
- repair Apps SMMU registration and reattach UFS, QUP, and DWC3 clients
- restore Qualcomm ICE support for UFS

## Priority 1: local interaction

- preserve the working native display clocks, DSI, DSC, Samsung panel, and
  persistent framebuffer console while the userspace package is finalized
- repeat graphical boots of the accepted clean Plasma Mobile image and retain
  package, filesystem, display, input, radio, and USB attestations
- retain the validated fixed 90 Hz mode, then implement panel-aware dynamic
  60/90 Hz switching and validate frame pacing, blank/unblank, and suspend/resume
- validate S6SY761 suspend/resume and touch wake after the successful Weston
  and Plasma Mobile orientation tests
- capture physical volume-key events, then validate wake behavior
- validate haptics and extend the working basic battery/charging support to
  cable transitions, termination, thermal limits, and suspend

## Priority 2: connectivity

- validate stable Wi-Fi MAC handling and sustained traffic after the successful
  NetworkManager association test
- extend the validated `r15` Bluetooth firmware, scan, HID connection, and
  disconnect path with repeated reconnects and longer bidirectional traffic
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
