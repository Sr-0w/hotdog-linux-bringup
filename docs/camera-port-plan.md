# SM8150 camera port: extracted hardware map and plan

This is the knowledge needed to write an SM8150 CAMSS backend, recovered from
sources rather than guessed. It exists so the driver work can start from facts.

## Why this is tractable

Three things de-risk the port, none of which were true when this was first
assessed against the 6.16 tree alone.

**The camera clock controller is already upstream and already described.**
`drivers/clk/qcom/camcc-sm8150.c` exists, `dt-bindings/clock/qcom,sm8150-camcc.h`
exists, and mainline `sm8150.dtsi` already carries
`camcc: clock-controller@ad00000` with `compatible = "qcom,sm8150-camcc"`. No
clock work is needed.

**A near neighbour is supported.** linux-next has `qcom,sm6150-camss`, the same
Titan generation. It uses `csiphy_ops_3ph_1_0` with `csiphy_formats_sdm845`,
and `csid_ops_gen2` with `csid_formats_gen2`, which is what SM8150 needs.
SM8150 differs mainly in count: four CSIPHYs rather than three, and lite
variants of CSID and VFE.

**The register map is published.** The OnePlus downstream kernel is GPL and its
`sm8150-camera.dtsi` gives every base address and interrupt.

## Hardware map

Taken from the OnePlus downstream `arch/arm64/boot/dts/qcom/sm8150-camera.dtsi`.
Interrupts are GIC SPI numbers.

| Block | Base | Size | IRQ |
| --- | --- | --- | --- |
| CCI0 | `0x0ac4a000` | `0x1000` | 460 |
| CCI1 | `0x0ac4b000` | `0x1000` | - |
| CSIPHY0 | `0x0ac65000` | `0x1000` | 477 |
| CSIPHY1 | `0x0ac66000` | `0x1000` | 478 |
| CSIPHY2 | `0x0ac67000` | `0x1000` | 479 |
| CSIPHY3 | `0x0ac68000` | `0x1000` | 448 |
| CSID0 | `0x0acb3000` | `0x1000` | 464 |
| VFE0 | `0x0acaf000` | `0x4000` | 465 |
| CSID1 | `0x0acba000` | `0x1000` | 466 |
| VFE1 | `0x0acb6000` | `0x4000` | 467 |
| CSID lite0 | `0x0acc8000` | `0x1000` | 468 |
| VFE lite0 | `0x0acc4000` | `0x1000` | - |
| CSID lite1 | `0x0accf000` | `0x1000` | 359 |
| VFE lite1 | `0x0accb000` | `0x1000` | - |

## Clocks

From `dt-bindings/clock/qcom,sm8150-camcc.h`, the identifiers the resource
tables will need:

- per CSIPHY: `CAM_CC_CSIPHY{0..3}_CLK` and `CAM_CC_CSI{0..3}PHYTIMER_CLK`,
  with `CAM_CC_CPHY_RX_CLK_SRC` shared
- per IFE: `CAM_CC_IFE_{0,1}_CLK`, `_CSID_CLK`, `_CPHY_RX_CLK`, `_AXI_CLK`
- CCI: `CAM_CC_CCI_{0,1}_CLK`

## Sensors on this handset

Identified from the stock vendor per-sensor modules, not from the device tree,
which only describes slots and CSIPHY assignment.

| Role | Sensor | Upstream driver |
| --- | --- | --- |
| Main 48 MP | Sony IMX586 | absent |
| Ultra-wide | Sony IMX481 | absent |
| Telephoto | Samsung S5K3M5 | present in linux-next |
| Front, pop-up | Sony IMX471 | absent |

The stock device tree assigns `cam-sensor@0..6` across the four CSIPHYs. Seven
slots for four physical sensors reflects the shared vendor image, so the actual
mapping has to be confirmed against this handset rather than assumed.

## What reuse means here

The OxygenOS userspace cannot be reused: `camera.qcom.so` and the per-sensor
`com.qti.sensor.*.so` modules are proprietary binaries, and the downstream
`cam_req_mgr` architecture has nothing in common with mainline CAMSS. The
downstream kernel is useful for register sequences, power-up ordering and clock
rates, which is knowledge reuse, exactly as this project's
[OxygenOS reuse policy](evidence/2026-08-05-oxygenos-hardware-reference.md)
already sets out for published OnePlus kernel source.

## Progress

**Done, revision `r51`.** The SoC side is written and builds.

`0055` adds `qcom,sm8150-camss` to `camss.c`: four CSIPHYs, two CSIDs and two
VFEs. The template is SDM845 rather than SM6150, because the 6.16 tree this
port builds from predates the SM6150 backend and already carries SDM845, which
is the same Titan generation and uses the same `csiphy_ops_3ph_1_0`,
`csid_ops_gen2` and `vfe_ops_170`. Its clock names, rates and power domains
carry over unchanged. The version reuses `CAMSS_845`, as SDM670 already does.

`0056` adds the `camss` node to `sm8150.dtsi` with the register bases,
interrupts, 31 clocks, IFE and Titan-top power domains, and the eight SMMU
streams from the map above. One substitution was needed: SDM845's `soc_ahb`
maps to `CAM_CC_CORE_AHB_CLK` here, because SM8150's camera clock controller
has no `CAM_CC_SOC_AHB_CLK`.

The node is left `disabled`, since it is only useful on a board that also
describes sensors. Verified in the built package: `qcom-camss.ko` is produced,
and the device tree carries the node with all eight register names, the three
power-domain names and 31 clocks.

The lite CSID and VFE instances the SoC also has are deliberately left out.
The full instances are what a sensor needs to stream.

**Also done, revision `r52`.** `0057` adds the two CCI blocks, which is how
sensors are reached at all: nothing can talk to them over a QUP bus. SM8150 has
two blocks of two buses each, unlike SDM845's one. Both are described with
their register bases, interrupts, per-block clocks and pin states, and left
disabled. The CCI driver has no SM8150 entry but the block is the SDM845 one,
so the compatible falls back to it.

## The board layout, recovered

The stock overlay carries two sensor layouts, because the vendor image is
shared. `fragment@47` has seven sensors and targets the generic Qualcomm
reference; `fragment@80` has four, each with its own `CAM_VANA` rail, which
matches this handset's three rear sensors plus the pop-up:

| Slot | CSIPHY | CCI master |
| --- | --- | --- |
| 0 | 1 | 1 |
| 1 | 0 | 0 |
| 2 | 2 | 0 |
| 3 | 3 | 1 |

Which physical sensor sits in which slot is not stated anywhere in the device
tree, and should be read from the hardware by its chip ID rather than assumed.

CCI pins are GPIO 17/18 and 19/20 for the first block, 31/32 and 33/34 for the
second. MCLK0 is GPIO 13.

## Per-slot wiring, recovered from `fragment@80`

| Slot | CSIPHY | CCI | MCLK GPIO | RESET GPIO | VANA control | vdig min |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 1 | 1 | 14 | 30 | GPIO 11 and 29, plus PMIC GPIO 1 | 1.104 V |
| 1 | 0 | 0 | 13 | 28 | GPIO 148 | 1.056 V |
| 2 | 2 | 0 | 15 | 12 | PMIC GPIO 12 | 1.056 V |
| 3 | 3 | 1 | 16 | 23 | PMIC GPIO 2 | 1.056 V |

All four declare `cam_vio`, `cam_vana`, `cam_vdig` and `cam_clk`, with
`cam_vana` at 3.3 V. The digital rails come from PM8009, the dedicated camera
PMIC: the fixups tie `pm8009_l1`, `pm8009_l3` and `pm8009_l4` to `cam_vdig` on
this fragment. `cam_vana` is switched by the per-slot GPIOs above rather than
being a plain regulator, so each sensor needs both a supply and a switch.

MCLK maps by index onto `CAM_CC_MCLK0_CLK` through `CAM_CC_MCLK3_CLK`.

### One conflict to resolve before wiring

`fragment@80` sets `clock-rates = <19200000>` for every slot, while
`fragment@47`, the generic Qualcomm layout, uses 24 MHz. The upstream S5K3M5
driver accepts only 24 MHz and rejects anything else at probe. Either the
telephoto really runs at 19.2 MHz here, in which case the driver needs a second
supported rate and its register sequences checked against it, or the 19.2 MHz
figure belongs to a different variant in the shared image. This has to be
settled before concluding anything from a failed probe.

### The PM8009 rails are partly missing

PM8009, the dedicated camera PMIC, is already described in
`sm8150-oneplus-common.dtsi`, which removes one worry. But only three of its
LDOs are declared: `vreg_l2f_1p2` at 1.2 V, `vreg_l5f_2p85` at 2.85 V and
`vreg_l6f_2p85` at 2.856 V.

The stock overlay drives `cam_vdig` from `pm8009_l1`, `pm8009_l3` and
`pm8009_l4`, none of which exist here, and asks for 1.056 V and 1.104 V rather
than 1.2 V. So before any sensor can be described, the missing LDOs have to be
added to the PM8009 block with the voltages the sensors actually want.

That is the next concrete edit, and it is small and well defined.

## Progress on the sensor

**Done, revision `r53`.** `0058` backports the S5K3M5 driver from linux-next.
Almost everything it needs is already here; the exception is
`devm_v4l2_sensor_clk_get()`, a newer helper that falls back to a fixed-rate
clock when no phandle is present. The clock is described on this board, so
plain `devm_clk_get()` is equivalent. It builds as a module. Nothing describes
the sensor yet, so it does not probe.

### Suggested discovery method

Which physical sensor occupies which slot is stated nowhere. The driver checks
the chip ID at probe, so describing the S5K3M5 on several slots and seeing
which one probes identifies the telephoto empirically, provided the MCLK
question above is settled first.

## Remaining

1. add the missing PM8009 LDOs, `l1`, `l3` and `l4`, at the voltages the
   sensors ask for
2. settle the 19.2 versus 24 MHz MCLK question
3. wire the hotdog device tree: enable `camss` and the CCI buses, describe the
   PM8009 rails and the VANA switches, and add the sensor nodes
4. confirm the telephoto path end to end
5. write IMX586, IMX481 and IMX471 using the downstream register sequences
6. libcamera pipeline configuration
7. optionally add the lite instances, and a binding YAML before submission

Step 2 is the useful milestone: it proves the CAMSS port with a sensor driver
that already exists, before any new sensor driver is written.
