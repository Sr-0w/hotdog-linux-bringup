# USB role switching - 2026-08-07

## Result

The Type-C port is managed and dual-role, host mode works, SuperSpeed works,
and DisplayPort alternate mode drives an external monitor. A powered Type-C
dock provides USB, gigabit Ethernet, mass storage and video while the handset
takes power from it.

## Starting point

The controller was pinned to peripheral mode:

```
&usb_1_dwc3 {
	dr_mode = "peripheral";
	...
};
```

Nothing drove a role switch, the PM8150B Type-C block and its VBUS boost were
both left `disabled`, and the FSA4480 endpoint added with the switch itself was
left dangling. Host mode was therefore not reachable at all, and `/sys/class/typec`
did not exist.

## Change

Revision `r42` (`0048`) describes the port the way the other SM8150 handsets
with this PMIC do, following `sm8150-xiaomi-nabu`, which is the closest match:
an SM8150 device that is also USB 2.0 only and also uses an FSA4480.

- enable `pm8150b_typec` with `vdd-pdphy-supply` and a dual-role
  `usb-c-connector`, with source and sink PDOs;
- enable `pm8150b_vbus` so the port can source;
- switch the controller to `dr_mode = "otg"` and add `usb-role-switch`;
- terminate both connector endpoints: the controller high-speed port for the
  data role, and the FSA4480 for orientation and SBU muxing.

No kernel configuration change was needed. `CONFIG_TYPEC`, `CONFIG_TYPEC_TCPM`,
`CONFIG_TYPEC_QCOM_PMIC`, `CONFIG_TYPEC_MUX_FSA4480`, `CONFIG_USB_ROLE_SWITCH`,
`CONFIG_REGULATOR_QCOM_USB_VBUS`, `CONFIG_USB_DWC3_DUAL_ROLE`,
`CONFIG_USB_XHCI_HCD` and `CONFIG_USB_STORAGE` were already enabled. This was a
device-tree gap only.

## Hardware state after the change

Booted as `#43-oneplus-hotdog-mainline616`, attached to a host PC:

```
/sys/class/typec/port0
  power_role  source [sink]
  data_role   host [device]
  usb_power_delivery_revision  3.0
/sys/class/typec/port0-partner        <- the PC is detected
```

The port correctly negotiates itself into sink and device while attached to a
PC, and USB networking continues to work, so the existing peripheral path is
not regressed.

The VBUS boost is registered and idle, which is what a sink should show:

```
usb_vbus   0 users   2000mA
   c440000.spmi:pmic@2:typec@1500-vdd-vbus
```

`qcom,pmic-typec` reports PD signalling activity in the log, so the TCPM stack
is live rather than merely probed.

## Host mode on hardware

Attached to a powered Type-C dock, the port switched itself to host while
staying a power sink, which is the interesting combination: the dock supplies
the handset and the handset drives the bus.

```
/sys/class/typec/port0
  power_role  source [sink]
  data_role   [host] device
```

The host stack came up and the dock enumerated:

| Device | ID | Detail |
| --- | --- | --- |
| `usb1` / `usb2` | `1d6b:0002` / `1d6b:0003` | xHCI root hubs |
| `1-1` | `05e3:0610` | GenesysLogic USB2.1 Hub, 4 ports |
| `1-1.1` | `0bda:8153` | Realtek USB 10/100/1000 LAN, high speed |

The Ethernet adapter bound to `r8152 v1.12.13` and created `eth0`. No link was
established because no cable was attached to the dock; `ethtool` reports
`Link detected: no`, and NetworkManager declines the device for want of a
carrier. Enumeration and driver binding are the parts this change is
responsible for, and both work.

Power delivery negotiated with the dock at the same time:

```
pm8150b-charger                                 online=1  status=Full
tcpm-source-psy-...typec@1500                   online=1
usb_vbus                                        0 users
```

The VBUS boost correctly stays off, because the handset is sinking rather than
sourcing. USB networking over the previous peripheral path is unregressed when
attached to a plain host PC.

The `r8152` driver logs a missing `rtl_nic/rtl8153b-2.fw` firmware patch. That
is an optional performance/errata patch, not required for the adapter to work,
and it is a firmware packaging item rather than a device-tree one.

## Mass storage

A SanDisk Cruzer Fit (`0781:5571`) attached through the dock enumerated as
`usb-storage`, produced `/dev/sdg` with its partition table, mounted read-only,
and sustained a 64 MiB sequential read at 6.0 MB/s. The rate is the stick's own
limit rather than the bus.

## SuperSpeed and DisplayPort

Revision `r43` (`0049`) removed the USB 2.0-only description. The results on the
same dock:

| Device | Speed |
| --- | --- |
| `2-1` GenesysLogic USB3.1 Hub | 5000 |
| `2-1.1` Realtek gigabit adapter | 5000 |
| `usb2` root hub | 10000 |

So the combo PHY and the SuperSpeed path work.

DisplayPort alternate mode is negotiated and an external monitor is driven:

```
/sys/class/typec/port0-partner/port0-partner.1   svid=ff01  active=yes
/sys/class/drm/card0-DP-1                        connected  enabled
modes: 2560x1440, 1920x1080, ...                 EDID: 384 bytes, MAG 271QPX
/sys/kernel/debug/dri/0/state
  connector[36]: DP-1   crtc=crtc-1
```

The DisplayPort controller binds to the DPU (`bound
ae90000.displayport-controller`), the `typec_displayport` altmode driver loads,
the monitor's EDID is read, and a CRTC is assigned to the connector, so a mode
is set and the pipeline is scanning out. The internal DSI panel keeps its own
connector and CRTC at the same time.

## External display: usable at 60 Hz, corrupt at 120 Hz

The desktop reaches the monitor, but KWin initially selected
`2560x1440@120.00` while the monitor's preferred mode is `2560x1440@59.95`.
At 120 Hz the picture was recognisable but permanently corrupt, looking like
fixed tearing. Selecting 60 Hz makes it correct, confirmed by eye.

`dp_debug` explains it. The link trains at HBR2 on two lanes, because the other
two carry USB3 in the DisplayPort-plus-USB pin assignment:

| Mode | pixel clock | bpp chosen | payload | 2-lane HBR2 budget |
| --- | --- | --- | --- | --- |
| 2560x1440@120 | 497,750 kHz | 18 | ~8.96 Gbps | ~8.64 Gbps |
| 2560x1440@60 | 241,500 kHz | 30 | ~7.25 Gbps | ~8.64 Gbps |

At 60 Hz the driver picks 30 bpp and fits comfortably. At 120 Hz it does not
reject the mode; it degrades colour depth to 18 bpp to try to make it fit, and
still exceeds the budget. Six bits per colour would look wrong even if it did
fit.

This looks like a driver defect rather than a board description problem: mode
validation should prune modes the trained link cannot carry at a sane depth,
instead of silently dropping to 18 bpp. It is worth reporting upstream. Nothing
in this device tree selects the mode, so it is not fixable here.

Practical consequence: the external display is usable, but 60 Hz has to be
selected. Four-lane DisplayPort would raise the ceiling at the cost of dropping
USB3 to USB2, which is the standard trade-off in the pin assignments and is not
currently exercised.

## DisplayPort audio: everything binds, the DSP refuses the port

Video over the dock works. Sound through it does not, and this is not solved.

Three defects were found and fixed on the way, all real:

- `r44` (`0050`) adds the missing back end. The DisplayPort controller
  registers an `hdmi-audio-codec` and carries `#sound-dai-cells`, and the DSP
  knows `DISPLAY_PORT_RX`, but the sound card referenced neither.
- `r45` (`0051`) teaches the machine driver the DAI id, which none of its three
  switches listed, so every open, configure and close logged
  `invalid dai id 0x68`.
- `r46` (`0052`) fixes an upstream bug: `DISPLAY_PORT_RX` is a receive port but
  was declared `SND_SOC_DAPM_AIF_OUT`, while every other receive port in
  `q6afe-dai.c` uses `SND_SOC_DAPM_AIF_IN` and only transmit ports use
  `AIF_OUT`. This one is worth sending upstream on its own merits.

The Linux side is now complete and verifiable. The card registers the codec as
a component:

```
/sys/kernel/debug/asoc/OnePlus 7T Pro/hdmi-audio-codec.0.auto
```

`CONFIG_SND_SOC_HDMI_CODEC` is built, `hdmi-audio-codec.0.auto` is bound to its
driver, and the `DISPLAY_PORT_RX` mixer controls exist. Playback still fails at
the same point:

```
qcom-q6afe: AFE enable for port 0x6020 failed -110
q6afe-dai: ASoC error (-110): at snd_soc_dai_prepare() on DISPLAY_PORT_RX_0
```

`-110` is a timeout: the ADSP does not answer the request to start
`AFE_PORT_ID_HDMI_OVER_DP_RX` at all.

### A wrong argument, corrected

An earlier version of this document argued that the stock configuration proves
the firmware supports DisplayPort audio, because the OxygenOS odm
`mixer_paths.xml` has 107 references to display-port paths. That argument does
not hold. The same file is Qualcomm reference boilerplate shipped unchanged: it
also contains 217 references to headphone and HPH paths on a handset with no
3.5 mm jack, and WSA speaker paths on a handset that uses TFA9874 amplifiers.
Its contents say nothing about what this device's DSP firmware actually
implements.

### Leading hypothesis

The OnePlus 7T Pro never shipped DisplayPort output, so the ADSP firmware image
on it plausibly does not provision the HDMI-over-DP AFE port. Video is
unaffected because it never involves the DSP. That would make this unfixable
from Linux with the stock firmware.

This is a hypothesis, not a conclusion. What would settle it: comparing against
an SM8150 device where q6afe DisplayPort audio is known to work, and inspecting
the ADSP image for the port. Until then the honest statement is that everything
under our control is correct and the DSP will not start the port.

The back end is left in place because it is correct and inert: nothing selects
it and the speaker profile is untouched.

## Not yet validated





The handset has not yet had to source VBUS itself, because the dock supplied
power. An unpowered peripheral, which forces the port into source, is still
untested, as is HID.

On the desktop side, only the kernel pipeline is proven. Whether the Plasma
session places a usable desktop on the external output, how it behaves on
hotplug, and multi-monitor or rotation handling are all separate userspace
questions.

The `r8152` driver logs a missing `rtl_nic/rtl8153b-2.fw` patch. It is optional
and the adapter works without it, but it is worth packaging.
