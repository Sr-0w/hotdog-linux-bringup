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

## Order of work

1. add `qcom,sm8150-camss` to `camss.c`: CSIPHY, CSID and VFE resource tables
   plus interconnect paths, modelled on `sm6150` and widened to four CSIPHYs
2. add the binding YAML
3. add the `camss` node to `sm8150.dtsi` using the map above
4. wire the hotdog device tree: CCI buses, CSIPHY assignment, sensor
   regulators and their power sequences from the downstream tree
5. take `s5k3m5` from upstream and confirm the telephoto path end to end first,
   because it is the only sensor that needs no new driver
6. write IMX586, IMX481 and IMX471 using the downstream register sequences
7. libcamera pipeline configuration

Step 5 is the useful milestone: it proves the CAMSS port with a sensor driver
that already exists, before any new sensor driver is written.
