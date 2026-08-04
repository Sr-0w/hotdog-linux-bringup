# Mainline 6.16 dynamic refresh validation

Date: 2026-08-05

Device: OnePlus 7T Pro HD1913 (`hotdog`)

## Result

Revision `r17` boots directly from the OnePlus bootloader and exposes the stock
1440x3120 60 Hz and 90 Hz modes to Plasma Mobile. Both scripted KScreen changes
and the refresh-rate selector in Plasma System Settings switch the physical
panel successfully. The compositor, touchscreen, USB networking, and SSH remain
available across the mode changes.

The active DRM state after the final manual selection was:

```text
mode: "1440x3120": 90 415457 1440 1456 1464 1472 3120 3124 3128 3136
```

KScreen reported 90 Hz as both active and preferred, with 60 Hz available:

```text
1440x3120@90.00*!
1440x3120@60.00
```

The panel driver sends the stock `0x20` control-display payload for 60 Hz and
`0x30` for 90 Hz. Kernel messages confirmed each selected mode rather than
inferring refresh from the user interface.

## Reproducible package and image

Two strict pmbootstrap builds produced identical kernel and DTB payloads. The
hardware-tested outputs are:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r17.apk` | 25,537,453 bytes | `e0b719869300370ea5aafe5a3f08ff628adc4334ccacde501da6303446197912` |
| `boot/vmlinuz` | 27,572,232 bytes | `69aa8aba33e268538cabeec405ac0fc7baf802138219f161b2ad6832ce350f1c` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 140,573 bytes | `512f71ef5bd70198cbe45ce6a9738370e8e43d294d2b3b3e9d33e54c54be3bf0` |

The AVB-valid 96 MiB partition image has SHA256
`d93ec3b84cc2cb726cbfbdd932d1d40a5b2e2e3574a0a7c4615c9a4c125d43f0`
and reports kernel build `#18-oneplus-hotdog-mainline616` after direct boot.

## Display stability boundary

Repeated 60/90 Hz changes completed without losing Linux, USB, or SSH. One
blank/unblank sequence produced a purple panel while the system remained fully
reachable. Locking and unlocking the Plasma session restored correct scanout
without rebooting. The kernel recorded bursts of `dsi_err_worker: status=5`,
which represents DSI timeout and FIFO status bits. Similar messages were seen
on the fixed-mode predecessor, so this is tracked as a panel blank/unblank
robustness issue rather than a failed dynamic-refresh implementation.

A later controlled package-install test ended in Qualcomm `900e`. The failure
was reproduced during a Flatpak pull with deployment disabled and the UFS
controller forced to `active/on`; there was no panic, oops, call trace, UFS
error, or ext4 error. Direct read/write and random-I/O controls passed. The
remaining boundary is a large buffered OSTree import, documented in the
[Flatpak/UFS evidence](2026-08-05-mainline616-flatpak-ufs.md). It is not counted
as a refresh-switch failure.

## Remaining work

- make panel blank/unblank reliable without DSI timeout/FIFO errors;
- measure frame pacing and sustained GPU/display load at both refresh rates;
- isolate the storage-load `900e` transition before using Discover as a stress
  workload again;
- validate complete suspend/resume only after DWC3 and touchscreen resume are
  repaired.
