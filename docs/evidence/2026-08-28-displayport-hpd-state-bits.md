# DisplayPort EDID recovery needs the corrected HPD state bits

Date: 2026-08-28

## Symptom

On the clean 6.17 Hotdog image the dock reached USB host mode, enumerated both
GenesysLogic hubs, RTL8153 Ethernet and USB storage, and reported the DRM
DisplayPort connector as connected. The monitor still appeared as an unknown
output: the EDID sysfs file was empty, only fallback modes were available and
the HDMI codec reported an invalid ELD.

That failure exists below PipeWire. Starting DisplayPort audio while EDID and
mode negotiation were already broken produced repeated QDSP6 AFE port `0x6020`
timeouts and eventually crossed a 900e boundary during DP audio teardown.

## Upstream defect

The 6.17 base contains the defect fixed by upstream commit
`2e6c2e81d81251623c458a60e2a57447dcbc988e`:

```text
drm/msm/dp: fix HPD state status bit shift value
```

`REG_DP_DP_HPD_INT_STATUS` stores the HPD state in bits 31:29. The base masks
four bits after shifting by 28, so `msm_dp_aux_is_link_connected()` can return
the wrong state. That helper decides whether an AUX failure should reset the
controller before retrying, which directly affects DPCD and EDID recovery.

The upstream correction is limited to:

```c
#define DP_DP_HPD_STATE_STATUS_BITS_MASK  0x00000007
#define DP_DP_HPD_STATE_STATUS_BITS_SHIFT 0x1d
```

It is staged alone on `bringup/hotdog-sm8150-dp-hpd-status`.

## Hardware A/B

The integration images use the same fresh Plasma Mobile rootfs, dock, monitor,
GEM ownership fix, SM8150 DP jack callback and UCM configuration.

Without this upstream fix, r35 reports:

```text
status=connected
edid_size=0
failed to get DP sink modes, rc=0
HDMI: Unknown ELD version 0
```

With only the HPD status fix added, r36 initially provides safe fallback modes.
After selecting the monitor's USB-C input it recovers the complete 384-byte
EDID and programs the real external mode:

```text
status=connected
edid_size=384
mode=2560x1440@60
link=HBR2 x2
pixel_clock=241500 kHz
```

The r36 AVB boot image SHA256 is
`7e64942b2970252cca44a5fc6941c14f6b90f6f510450df7622cd928090935ab`;
the kernel package SHA256 is
`39a6ae872878aa3f114a4d7f7f9fe17da1ebe5ff617403c59d6521bef43f805a`.
Both the kernel build validation and AVB verification pass.

## Gate

Status: **EDID, mode negotiation and visual output PASS; repeated hotplug
remains pending**.

The monitor displayed the Plasma desktop at the negotiated mode after its
USB-C input was selected. This closes the visual part of the gate: r36 did not
merely populate sysfs, it drove a usable external image at 2560x1440@60.

DisplayPort audio is a separate gate. No audio was played during this proof,
and this fix does not claim to repair AFE port `0x6020`.
