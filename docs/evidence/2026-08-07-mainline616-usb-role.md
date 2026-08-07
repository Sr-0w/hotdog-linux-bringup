# USB role switching - 2026-08-07

## Result

The Type-C port is managed, dual-role, and host mode works on hardware. A
powered Type-C dock enumerates through it while the handset simultaneously
takes power from that dock.

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

## Not yet validated


The handset has not yet had to source VBUS itself, because the dock supplied
power. An unpowered peripheral, which forces the port into source, is still
untested, as is mass storage and HID.

This change is USB 2.0 only. The QMP PHY stays disabled and the controller
keeps `maximum-speed = "high-speed"`, so SuperSpeed and DisplayPort alternate
mode over the dock are untouched and remain future work.
