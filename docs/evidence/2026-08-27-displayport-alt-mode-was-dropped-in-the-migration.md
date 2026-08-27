# DisplayPort: the alt mode was dropped in the migration

Date: 2026-08-27

A UGREEN dock produced no HDMI signal on 6.17, on hardware where the same dock
had worked on 6.16.

## The dock was never the problem

It enumerates completely: a GenesysLogic 4-port hub, a Realtek RTL8153 gigabit
adapter and a SanDisk mass storage device that mounts as `sdg`. Power delivery
negotiates, the dock charges the phone, and `port0-partner` registers with
`power_operation_mode = usb_power_delivery`.

The partner advertises both of its alternate modes:

```
port0-partner.0  svid=057e  active=no
port0-partner.1  svid=ff01  active=no
```

`ff01` is DisplayPort. It is advertised and never entered.

## The port had no alternate mode to enter

`/sys/class/typec/` held only `port0` and `port0-partner` — no `port0.N`. The
port side registered no alternate mode at all, so there was nothing to enter and
`typec_displayport`, though loaded, had nothing to bind. Writing the partner's
`active` is refused, which is correct: entry is driven from the port.

A port's alternate modes come from the device tree, under the connector's
`altmodes` node. The 6.17 board file had none. The 6.16 series carried exactly:

```
altmodes {
	displayport {
		svid = /bits/ 16 <0xff01>;
		vdo = <0x00001c46>;
	};
};
```

so this is a migration regression, not a missing description. `sm8150-hdk` and
`qrb5165-rb5` carry the same node upstream.

## Validated

`r14`, with the node restored: the phone's console appears on the monitor
through the dock. Video leaves the phone over DisplayPort again.

## Not this bug

The `Broken` entry for 2560×1440@120 is a separate defect and remains open. Its
cause is identified but unvalidated: `msm_dp_bridge_mode_valid()` halves
`mode_pclk_khz` when wide bus is available — correct for the
`DP_MAX_PIXEL_CLK_KHZ` check, since wide bus carries two pixels per clock on the
DPU→DP interface — and then reuses the halved value to compute link bandwidth,
which the link does not halve. For two-lane HBR2 the budget is 8,640,000; the
mode needs 469,150 × 24 = 11,259,600 and is correctly rejected, but the halved
form gives 5,629,800 and passes. `msm_dp_panel_get_supported_bpp()` receives the
same halved clock and overestimates bpp too. Every msm controller with
`wide_bus_supported` is affected.

## The 120 Hz mode, fixed and validated

`r15`, on the same dock and monitor. `2560x1440` now appears **once** in the
connector's mode list where it appeared twice before, and the owner reports the
external output is clean — no tearing.

The fix separates the two clocks that `msm_dp_bridge_mode_valid()` had shared.
The DPU-to-DP interface clock is genuinely halved by a wide bus, which is what
the `DP_MAX_PIXEL_CLK_KHZ` ceiling is about; the link is not, because every
pixel still crosses the lanes. Only 4:2:0 halves the data.

Refusing the mode is the correct outcome, not a limitation introduced by the
patch: two lanes of HBR2 give 8,640,000 and the mode needs 469,150 × 24 =
11,259,600. It was never drivable, only accepted.
