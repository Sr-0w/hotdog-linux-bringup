# USB role switching - 2026-08-07

## Result

The Type-C port is now managed and dual-role capable. Host mode is reachable in
software; enumerating a device through it is not yet validated on hardware.

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

## Not yet validated

Nothing has been attached with the handset acting as host. What remains is to
attach a peripheral or a dock and confirm the port switches to source and host,
that VBUS actually comes up, and that a device enumerates through xhci.

This change is USB 2.0 only. The QMP PHY stays disabled and the controller
keeps `maximum-speed = "high-speed"`, so SuperSpeed and DisplayPort alternate
mode over the dock are untouched and remain future work.
