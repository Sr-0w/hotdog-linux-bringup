# The ADSP does implement HDMI-over-DP

Date: 2026-08-27

DisplayPort audio fails with the ADSP never answering:

```
qcom-q6afe: AFE enable for port 0x6020 failed -110
q6afe-dai: ASoC error (-110): at snd_soc_dai_prepare() on DISPLAY_PORT_RX_0
```

[2026-08-07-mainline616-usb-role.md](2026-08-07-mainline616-usb-role.md) closed
on a hypothesis: the OnePlus 7T Pro never shipped DisplayPort output, so its
ADSP image plausibly does not provision the HDMI-over-DP AFE port, *"which would
make this unfixable from Linux with the stock firmware"*. It named the test that
would settle it — inspect the ADSP image for the port.

## The hypothesis is refuted

`adsp.mbn` carries a complete HDMI-over-DP output driver:

```
AFEHdmiOutputDrv.cpp: AFE_PARAM_ID_HDMI_DPTX_IDX_CFG setparam done.
                      DPTX index: %u, intf: 0x%x
AFEHdmiOutputDrv.cpp: AFE_PARAM_ID_HDMI_DP_MST_VID_IDX_CFG setparam done.
                      MST index: %u, intf: 0x%x
AFEHdmiOutputDrv.cpp: ELITEMSG_CUSTOM_HDMI_OVER_DP, Received MUTE DONE
AFEHdmiOutputDrv.cpp: ELITEMSG_CUSTOM_HDMI_OVER_DP, Received UNMUTE DONE
AFEHdmiOutputDrv.cpp: HDMI DP mst config fail: Invalid payload size
AFEHdmiOutputDrv.cpp: HDMI hardware doesn't support dptx config.
```

with two DMA back ends for it, `AFEHalDmaTypeHdmiV1` and `AFEHalDmaTypeHdmiV2`,
driving `LPASS_HDMITX_RDDMA_*`. The firmware is not missing the feature. It
names DisplayPort explicitly, distinguishes DP transmitters and even
multi-stream video indices.

So the port is not absent, and the problem is not out of reach from Linux.

## What that points at instead

The firmware expects to be told **which DP transmitter** a stream belongs to,
through `AFE_PARAM_ID_HDMI_DPTX_IDX_CFG`, and separately an MST video index.
Mainline `q6afe` sends exactly one parameter for this port:

```c
#define AFE_PARAM_ID_HDMI_CONFIG   0x00010210
...
cfg_type = AFE_PARAM_ID_HDMI_CONFIG;
```

There is no DPTX index anywhere in `q6afe.c`, and none in the DAI or machine
paths either. On a SoC whose audio can be routed to more than one DP
transmitter, a port started without that binding has nothing to attach to,
which is a plausible reason for a command that is never answered rather than
answered with an error.

This is a lead, not a demonstration. Confirming it needs the numeric value of
`AFE_PARAM_ID_HDMI_DPTX_IDX_CFG` and the payload layout, neither of which is in
the strings, plus a run against the hardware.

The other open possibility, not excluded by anything here, is a clock: the DMA
back end drives `LPASS_HDMITX`, and if the block is unclocked when the port
starts, the DSP would also wait forever.

## Correcting the record

The earlier note was careful to call its position a hypothesis and to name its
test, which is why this took one command to settle once the OxygenOS firmware
package was at hand. What it got wrong is the conclusion drawn in the status
tables, where "the ADSP times out" had hardened into "the firmware probably
cannot do it". It can. Nobody has yet told it which transmitter to use.

## How far the image can be read, and where it stops

`adsp.mbn` is `ELF 32-bit LSB executable, QUALCOMM DSP6`, stripped of section
headers but with intact program headers, and `llvm-objdump -d --triple=hexagon`
disassembles it whole — about 170 MB of listing. So the image is readable; the
difficulty is addressing.

Mapping works. The `AFE_PARAM_ID_HDMI_DPTX_IDX_CFG` log string sits at file
offset `0xd98ed6`, which the `LOAD` at `0xd55000 → 0xb1444000` places at virtual
address `0xb1487ed6`.

The AFE parameter dispatch is findable too. `AFE_PARAM_ID_HDMI_CONFIG` appears
exactly where it should, as an extended immediate in a comparison:

```
b04cd7c0: immext(#0x10200)
b04cd7c4: p0 = cmp.eq(r1,##0x10210)
```

What does not work is the usual shortcut of finding the code that logs a string
by searching for the string's address. These log pointers are formed
GP-relative:

```
b083ded0: r0 = add(r8,#0x1585)
```

so no absolute address appears in the instruction stream and there is nothing to
grep for. Recovering the DPTX parameter ID means resolving the base register for
that region and walking the handler that emits the message — a focused piece of
work rather than a one-liner, and the natural continuation of this note.

The alternative that settles it in one step is Qualcomm's public downstream
`apr_audio-v2.h`, which defines these identifiers outright. That is a lookup,
not reverse engineering, and it is worth doing before spending the Hexagon
effort.

## The identifiers, and what the firmware demands of them

Qualcomm's public downstream `apr_audio-v2.h` defines them outright:

```c
#define AFE_PARAM_ID_HDMI_CONFIG                 0x00010210
#define AFE_PARAM_ID_HDMI_DP_MST_VID_IDX_CFG     0x000102b5
#define AFE_PARAM_ID_HDMI_DPTX_IDX_CFG           0x000102b6
```

The header stops there: it declares no payload structure for either DP
parameter, and neither the OnePlus SM8150 downstream `q6afe.c` nor its
`msm-dai-q6-v2.c` uses them at all — consistent with a handset that never
shipped DisplayPort audio.

The firmware supplies what the header does not. With the numeric value in hand
the Hexagon image becomes searchable, and `0x102b6` appears five times. One site
is the payload-size validator, and the same shape repeats for each parameter:

```
b04bc218: r2 = memw(r16+#0x8)                       ; incoming payload size
b04bc21c: if (cmp.gtu(r2.new,#0xf)) jump 0xb04bc390 ; accept only if > 15
b04bc224: r0 = ##0xb082c620                         ; "Invalid payload size"
b04bc230: r1 = ##0x102b6;  r3 = #0x10               ; param 0x102b6, wants 0x10
```

and immediately above it, for the MST parameter:

```
b04bc1fc: if (cmp.gtu(r2.new,#0x3)) jump 0xb04bc370
b04bc210: r1 = ##0x102b5;  r3 = #0x4                ; param 0x102b5, wants 0x04
```

The register pair carried into the error logger is the parameter and the size it
expects, which the firmware's own message confirms:
`HDMI DP mst config fail: Invalid payload size: %ld, port_id: 0x%x`.

| parameter | id | payload |
| --- | --- | ---: |
| `AFE_PARAM_ID_HDMI_CONFIG` | `0x00010210` | as in mainline |
| `AFE_PARAM_ID_HDMI_DP_MST_VID_IDX_CFG` | `0x000102b5` | 4 bytes |
| `AFE_PARAM_ID_HDMI_DPTX_IDX_CFG` | `0x000102b6` | **16 bytes** |

What is still missing is the field layout inside those 16 bytes. The logging
text names two of them — `DPTX index: %u, intf: 0x%x` — and a Qualcomm parameter
payload of this shape conventionally opens with a minor-version word, but that
is inference and not yet read out of the image.
