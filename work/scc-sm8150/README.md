# SM8150 sensor clock controller: written, wrong, kept

These two patches build and produce a working driver, and they must not go
into the kernel package as they stand. `r170` carried them and the handset
would not boot: it reached display bring-up, scanned out uninitialised memory,
and looped.

## Why it hangs

`qcom_cc_probe()` maps the block and `clk_trion_pll_configure()` writes to it,
from the application processor, at boot. The stock device tree says plainly
that this is not the AP's block to touch:

```
qcom,scc@2b10000 {
	status = "disabled";
	compatible = "qcom,scc-sm8150-v2";
	vdd_scc_cx-supply = <&pm8150_l8_level>;
};
```

OxygenOS never drives it either. The sensor DSP brings up its own clocks. And
the supply named there, `pm8150_l8` in level mode, is not voted by anything on
the AP side, so the block is unpowered when the driver writes to it. An access
to an unpowered block does not fault, it stalls, which is the same failure this
work set out to fix, reproduced from the wrong side.

## What this means for the sensors problem

The controller being undescribed was a plausible explanation for the sensor
domain stalling the interconnect, and it is now a weaker one: if the AP is
meant to leave the block alone, its absence from the mainline device tree is
not by itself a defect.

The question the evidence file asks is still open, and the next thing to
compare is what powers the SSC island. Mainline's `remoteproc_slpi` votes
`SM8150_LCX` and `SM8150_LMX`. Whether that is the whole set the DSP needs
before it can reach its own clock controller is the thing to establish, and it
is a device tree question rather than a driver one.

## Keeping them

The driver itself is sound work and is not thrown away. It is 258 lines
against downstream's 745, with the voltage-vote scaffolding dropped and the six
identical serial-engine sources folded into macros, and every offset is
verified. If the SSC ever needs an AP-side clock provider, this is it. It would
need, at minimum, a power domain to hold before it touches a register.

## Finished: the application processor cannot drive this block

The driver was taken as far as it can go and the answer is negative. Recording
it properly so nobody spends another evening on it.

Two defects in the original were real and are fixed in the patches here:

- `clk_trion_pll_configure()` no longer runs at probe. The sensor DSP's own
  firmware configures the PLL, so writing it from the application processor was
  both unnecessary and the most dangerous thing the driver did.
- the node now holds `power-domains = <&rpmhpd SM8150_LCX>`, the island the
  sensor DSP itself votes for, so the block should be powered whenever the
  driver touches a register.

Neither is enough. Built as a module and kept off the boot path with a
blacklist, `modprobe scc-sm8150` blocks and the watchdog resets the handset.
That is a better failure than r170's unbootable image, and it is the same
failure: an access that never completes.

What settles it is what mainline does not describe. `gcc-sm8150.c` has no SSC
clocks at all, and `qcom,gcc-sm8150.h` has no SSC constants. There is no
described way for the application processor to enable access to the block, and
holding a power domain does not substitute for a clock that nothing gates.

That agrees with everything else. The stock device tree marks this node
`status = "disabled"` with `qcom,subsys-name = "slpi"`; OxygenOS never drives
it either; and the sensor DSP powers and clocks its own island from firmware.

## This costs nothing

The sensors do not need it. The sensor core publishes QMI service 400 on QRTR
node 9 and answers requests, which is the route that works and does not involve
this block at all.

The driver stays here because the register offsets, parent topology and
frequency tables are all verified against the downstream source, and because if
a future kernel ever describes the SSC access clocks this is most of the work
already done.
