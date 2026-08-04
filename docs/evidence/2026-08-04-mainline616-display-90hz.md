# Mainline 6.16 stock 90 Hz display validation

Date: 2026-08-04

Device: OnePlus 7T Pro HD1913 (`hotdog`)

Result: revision `r16` boots directly from the OnePlus bootloader into the
existing postmarketOS Plasma Mobile system and runs the native 1440x3120 panel
at 90 Hz. The active refresh is read from the DRM CRTC state, not inferred from
animation or compositor output. Storage, the read-write root filesystem, USB
networking, SSH, touch, the Adreno render node, Wi-Fi, and Bluetooth all remain
present on the same boot.

## Stock timing source

The 90 Hz values come from the decompiled stock HD1913 DTBO. Both tested A/B
DTBO partitions contained the same image, SHA256
`0a03f427d0fada29ca26655d2457f1085f71829833f59d7d7f5a2da114876ef4`.
The relevant OnePlus Samsung panel overlay describes these two modes:

| Property | Stock 60 Hz | Stock 90 Hz |
|---|---:|---:|
| Resolution | 1440x3120 | 1440x3120 |
| Horizontal front/sync/back porch | 16 / 8 / 8 | 16 / 8 / 8 |
| Vertical front/sync/back porch | 400 / 28 / 1156 | 4 / 4 / 8 |
| Refresh | 60 Hz | 90 Hz |
| DSI link clock | 1.1 GHz | 1.1 GHz |
| DRM pixel clock | 415457 kHz | 415457 kHz |
| Control-display payload | `0x20` | `0x30` |

Revision `r16` changes only the panel driver's mode timing and matching
control-display payload. The implementation is tracked as
[`0027-drm-panel-oneplus-select-stock-90hz-mode.patch`](../../aports/device/testing/linux-oneplus-hotdog-mainline616/0027-drm-panel-oneplus-select-stock-90hz-mode.patch).

The first hardware candidate intentionally exposes only the 90 Hz mode. The
generic panel interface used by this driver has no mode-set callback, so simply
advertising both modes would let userspace select 60 Hz without sending the
matching `0x20` panel command. Dynamic 60/90 Hz switching remains a separate
implementation task.

## Reproducible package

Two independent strict pmbootstrap builds produced byte-identical APKs and
passed the package contract validator:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r16.apk` | 25,537,088 bytes | `da7ebd249db076fa1a08058699141f08044197c9c84a6517c72e2cca2654b67f` |
| `boot/vmlinuz` | 27,572,232 bytes | `c5ca9d015d8be4902c0567c564c51e150bb6f7d032f75a57cdca5811c03c9407` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 140,573 bytes | `512f71ef5bd70198cbe45ce6a9738370e8e43d294d2b3b3e9d33e54c54be3bf0` |

The DTB is byte-identical to `r15`, as expected for a panel-driver source
change. The validator requires the exact stock 90 Hz timing and `0x30` payload
and rejects the previous fixed 60 Hz geometry.

## Exact boot image

The package kernel was assembled with the accepted `r15` DTB, initramfs, and
command line. The AVB-valid 96 MiB image has SHA256
`387f306785211f19542df9b3775018961da476995382d4abbfcb8f6caaa4f797`.
It was written only to `boot_b` from a live mainline system, read back in full
with the same digest, and then rebooted normally. The fresh direct boot reports:

```text
Linux hotdog 6.16.0-sm8150 #17-oneplus-hotdog-mainline616
```

The DRM debug state is authoritative for the active scanout:

```text
mode: "1440x3120": 90 415457 1440 1456 1464 1472 3120 3124 3128 3136
```

This exactly encodes the stock 16/8/8 horizontal and 4/4/8 vertical porches.
KWin independently reports the same refresh while composing through Freedreno:

```text
Name: DSI-1
Enabled: 1
Geometry: 0,0,480x1040
Scale: 3
Refresh Rate: 90000
Compositing is active
Compositing Type: OpenGL ES 2.0
OpenGL renderer string: FD640
```

Plasma Mobile is active on the same output, and the Adreno render node plus
S6SY761 touchscreen remain registered.

## Active-runtime observation

An unattended five-second monitor completed 152 samples through 919.76 seconds
of device uptime. Every completed sample still had the UFS-backed root
filesystem, configured DWC3 gadget, charger, and Bluetooth HCI present. The UFS
controller entered and left runtime suspend normally, while the Bluetooth IBS
counters and clock votes remained idle.

The host then recorded the postmarketOS USB device disconnecting 923 seconds
after enumeration, while the panel became black. No Qualcomm `900e` or `9008`
device, bootloader, recovery, or replacement USB personality appeared. Cycling
both halves of the handset's physical USB port from the host did not wake it.
The timing matches a 15-minute graphical-session idle deadline, so a system
suspend request is the leading hypothesis, but it is not yet proven. This event
is not counted as either a 90 Hz display failure or a successful suspend/resume
cycle until the next boot can provide pstore evidence or the same boot can be
resumed interactively.

## Remaining display work

1. Repeat the fixed-90-Hz window with automatic suspend inhibited.
2. Reproduce the 15-minute transition with pstore capture and a known wake
   source, then validate blank/unblank and touch wake without losing USB SSH.
3. Add a panel-aware atomic 60/90 Hz switch with matching DCS commands.
4. Measure frame pacing and sustained GPU/display load at 90 Hz.
5. Validate suspend/resume only after the active display path is repeatable.

The earlier fixed 60 Hz image remains the display fallback while dynamic mode
selection and power-state handling are developed.
