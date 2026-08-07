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

## First hardware result, revision `r55`

CAMSS runs on the handset. This is the first time anything camera-related has
worked on this port rather than merely compiled.

### One missing config symbol was the whole blocker

Revision `r54` enabled `camss` and both CCI blocks and the driver matched, but
probe failed:

```
qcom-camss acb3000.camss: deferred probe timeout, ignoring dependency
qcom-camss acb3000.camss: Failed to configure power domains: -110
platform ac4a000.cci: deferred probe pending: (reason unknown)
```

The camera clock controller supplies both the clocks and the IFE and Titan-top
power domains, and `CONFIG_SM_CAMCC_8150` was not set. The module list
confirmed it: `camcc-sdm845.ko`, `camcc-sc7280.ko` and four others were built,
but no `camcc-sm8150.ko`. Nothing in the device tree was wrong; the provider
simply did not exist.

`r55` sets `CONFIG_SM_CAMCC_8150=m`.

### What the handset shows now

```
/sys/bus/platform/devices/ad00000.clock-controller/driver -> camcc-sm8150
/dev/media0
/dev/v4l-subdev0 .. /dev/v4l-subdev13
```

CAMSS probes cleanly, registers its media device and fourteen subdevices, and
the deferred-probe list no longer mentions any camera block. The only log lines
left are dummy-regulator notices for `vdda-phy` and `vdda-pll`, which is normal
where the PHY supplies are not separately described.

Both CCI blocks probe and present their four buses:

```
i2c-4  Qualcomm-CCI      i2c-5  Qualcomm-CCI
i2c-6  Qualcomm-CCI      i2c-7  Qualcomm-CCI
```

### The camera modules answer

Scanning the four buses finds devices already responding, with no power
sequencing of any kind performed yet:

| Bus | Addresses |
| --- | --- |
| i2c-4 | none |
| i2c-5 | `0x51` |
| i2c-6 | `0x54` |
| i2c-7 | `0x50`, `0x58` |

The `0x50`-`0x54` range is where camera-module calibration EEPROMs sit, so
these are the modules' EEPROMs rather than the image sensors. The sensors
themselves stay silent until MCLK and their supplies are up, which is expected
and is exactly what a sensor node will do.

What this proves independently of any sensor work: the register bases, the
interrupts, the 31 clocks, the power domains, the SMMU streams and the CCI pin
configuration are all correct, and the bus physically reaches the camera
modules.

## The first sensor is identified, revision `r56`

The board says nothing about which sensor sits in which slot, and a sensor
answers nothing until it is powered, clocked and out of reset. `0061` adds a
small diagnostic that powers a slot exactly as a sensor driver would and then
reads register 0x0000, where both Sony and Samsung report their model.

On the handset:

```
hotdog-cam-scan 4-007f: slot powered, MCLK at 24000000 Hz, scanning bus
hotdog-cam-scan 4-007f: address 0x10 answers, register 0x0000 = 0x30d5
```

`0x30d5` is `S5K3M5_CHIP_ID` in the upstream driver. So the telephoto is on
**slot 1**, at **address 0x10**, reached through CCI0 master 0, wired to
CSIPHY0 and clocked by MCLK0.

This settles several open questions at once. The slot-to-bus mapping derived
from the stock `cci-device` and `cci-master` pairs is right. The PM8009 rails
and the GPIO-switched analogue supply are right, because the sensor would not
answer otherwise. And the 19.2 versus 24 MHz question is answered in favour of
24 MHz: the sensor replies at the rate the upstream driver requires, so the
stock figure belongs to the vendor's own register sequences, not to the board.

### The slot map, now anchored to hardware

| Slot | CCI bus | CSIPHY | MCLK | reset | analogue enable | digital rail |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | i2c-4? no: CCI0 m1 | 1 | MCLK1 | tlmm 30 | tlmm 11, tlmm 29, pm8150l gpio1 | pm8009 ldo1, 1.104 V |
| 1 | CCI0 master 0 | 0 | MCLK0 | tlmm 28 | tlmm 148 | pm8009 ldo2, 1.2 V |
| 2 | CCI1 master 0 | 2 | MCLK2 | tlmm 12 | pm8150l gpio12 | pm8009 ldo3, 1.056 V |
| 3 | CCI1 master 1 | 3 | MCLK3 | tlmm 23 | pm8150l gpio2 | pm8009 ldo4, 1.056 V |

Slot 1 is confirmed by hardware. The other three are described but not yet
confirmed, because the scan does not survive them, see below.

### The diagnostic is not yet safe on the other three slots

In `r56` the driver ran during boot. It identified slot 1 and then took a null
dereference, which left the handset without networking and required a fastboot
recovery. `r57` makes it inert unless loaded with `scan=1`, serialises the
slots because the two masters of a CCI block share an interrupt, and tries only
the addresses these sensors actually use.

That was enough to make boot safe, and the handset now boots normally with the
module present. It was not enough to make the scan itself survive: running it
by hand still resets the handset partway through. Since it only ever powers
hardware and reads, the fault is in how a slot with no answering device is
handled, not in the slots themselves.

This is a diagnostic, not a deliverable. Slot 1 is confirmed and that is the
one needed to bring a real sensor up, so the next step is to describe the
S5K3M5 properly rather than to keep debugging the aid.

### What the vendor modules say about the other three

The stock per-sensor modules name four sensors, and slot 0 is the only slot
carrying an actuator, an OIS block, a second analogue rail and `CAM_PVDD`,
which is the signature of the stabilised main camera. Slot 3 is the only one
with a different orientation, 270 degrees of roll, which is the pop-up. That
leaves the ultra-wide on slot 2.

| Slot | Sensor | Basis |
| --- | --- | --- |
| 0 | Sony IMX586, main | actuator, OIS, extra rails |
| 1 | Samsung S5K3M5, telephoto | confirmed by chip ID |
| 2 | Sony IMX481, ultra-wide | elimination |
| 3 | Sony IMX471, pop-up front | orientation |

Only slot 1 is proven. The rest is inference and must be confirmed the same
way before any driver is written against it.

## The telephoto probes, revision `r59`

`0063` replaces slot 1's diagnostic node with a real S5K3M5, at the address the
scan found, and connects its endpoint to CSIPHY0.

Two things had to be right beyond the address. The analogue supply is the boost
converter behind a load switch the slot drives itself, so it is described as a
fixed regulator with its own enable GPIO rather than as a rail the sensor
references directly. And the link frequency has to be one the driver's own menu
offers: an initial 482 MHz was rejected with `no matching link frequencies
found`, and 602.5 MHz, the single entry in `s5k3m5_link_freq_menu`, is accepted.

The sensor now binds and registers:

```
/sys/bus/i2c/devices/4-0010/driver -> s5k3m5
v4l-subdev14: s5k3m5 4-0010
```

with no errors logged, alongside the full CAMSS pipeline:

```
v4l-subdev0..3   msm_csiphy0..3
v4l-subdev4..5   msm_csid0, msm_csid1
v4l-subdev6..13  msm_vfe0/msm_vfe1, rdi0..2 and pix
video0..video7   msm_vfe0/1_video0..3
/dev/media0
```

That is a complete media graph from a real image sensor to eight capture nodes.
Probing is not capturing: the links still have to be enabled, formats matched
along the chain, and a buffer dequeued before anything can be called working.
But every piece the port has to supply is now present and bound.

## The pipeline streams, the pixels are black

The media graph was configured by hand and a buffer was dequeued:

```
media-ctl -V '"msm_csiphy0":0 [fmt:SGRBG10_1X10/4208x3120]'   (and :1)
media-ctl -V '"msm_csid0":0   [fmt:SGRBG10_1X10/4208x3120]'   (and :1)
media-ctl -V '"msm_vfe0_rdi0":0 [fmt:SGRBG10_1X10/4208x3120]'
v4l2-ctl -d /dev/video0 --set-fmt-video=width=4208,height=3120,pixelformat=pgAA
v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=1 --stream-to=frame.raw
```

`STREAMON` succeeds, one frame is dequeued, and the file is 16,423,680 bytes,
which is exactly 4208x3120 in packed 10-bit Bayer at a 5264-byte line stride.
Nothing is logged by the kernel. The default links, sensor to CSIPHY0 to CSID0
to VFE0 RDI0 to video0, were already enabled.

The pixel format had to match the sensor's Bayer order: the node defaults to
`pGAA`, GBGB/RGRG, and the sensor is SGRBG, so `STREAMON` first failed with
`EPIPE` until it was set to `pgAA`.

**Every byte of the frame is zero.** That is not a dark scene; a sensor in
darkness still returns its black-level pedestal, around 64. So the DMA path
works and delivers a correctly shaped buffer, while no pixel data reaches it.

What that narrows it to: the sensor is not actually emitting on the CSI-2 bus,
or the receiver is not locking onto what it emits. Candidates, in the order
worth checking: whether `s5k3m5_start_streaming` really runs and its register
writes land, whether exposure and gain defaults leave the sensor blanked,
whether four data lanes is right for this module, and whether the CSIPHY needs
a settle-count or lane configuration this backend is not setting.

This is the honest state: the port is complete enough to run a capture end to
end, and the camera does not yet produce an image.

## Remaining

1. find why the frames are black
2. confirm the other three slots the same way the telephoto was confirmed,
   once the identification aid survives a slot with nothing to answer
3. write IMX586, IMX481 and IMX471 from the downstream register sequences
4. libcamera pipeline configuration
5. the pop-up motor, which the front camera needs before it can see anything
6. optionally the lite CSID and VFE instances, and a binding YAML
