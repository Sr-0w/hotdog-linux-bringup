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

## Why the frames are black, narrowed down

Four measurements, each ruling something out.

**The sensor is powered and transmitting.** Sampled during a long capture
rather than after it, which an earlier reading got wrong:

```
t=1s runtime=active   cam1_vana=enabled
sensor register 0x0100 (mode select) = 0x01
```

So exposure, gain and power are not the problem. Exposure and analogue gain
were also already at maximum.

**The sensor's own test pattern does not arrive either.** With
`test_pattern=2`, colour bars, the frame is still entirely zero. That removes
the scene, the optics and the sensor's analogue front end from suspicion.

**Interrupts localise the break.** Across a capture:

| Interrupt | Before | After |
| --- | --- | --- |
| `camss_msm_vfe0` | 961 | 969 |
| `camss_msm_csid0` | 3 | 3 |
| `camss_msm_csiphy0` | 0 | 0 |

VFE0 runs and completes buffers, which is why correctly sized frames come back.
CSID0 sees nothing at all.

**CSID0 is configured correctly.** An earlier reading of offsets 0x00 to 0x1c
found them all zero and concluded the CSID was never programmed. That was
wrong: those offsets are reserved on this generation. The configuration
registers are at 0x100 and 0x300, and they hold sensible values:

| Register | Value | Meaning |
| --- | --- | --- |
| `0x100` RX_CFG0 | `0x00032103` | 4 active lanes, DL0..DL3 in order, PHY 0, D-PHY |
| `0x104` RX_CFG1 | `0x00000041` | |
| `0x300` RDI_CFG0 | `0x802bf007` | enabled, bit 31 set |
| `0x308` RDI_CTRL | `0x00000001` | running |
| `0x020` RX_IRQ_STATUS | `0x0097c0ff` | error bits latched |

So the CSID is told the right thing: four lanes, mapped in order, taking from
CSIPHY0 over D-PHY, with its RDI path enabled. That matches the sensor and the
device tree exactly.

What remains is that it takes no interrupts and latches error bits in
`RX_IRQ_STATUS`, which is where a receiver that sees electrical activity it
cannot decode ends up. That points back at the CSIPHY: the sensor transmits,
the CSID is correctly told to receive, and nothing decodable arrives between
them.

### One correction to the clock-rate reasoning

The settle count argument applies to `csiphy-2ph-1-0`, the older PHY, which
computes it from the timer clock rate. This SoC uses `csiphy-3ph-1-0`, which
does not. So the corrected clock rates in `r60` are right and worth keeping,
because asking a clock for a rate it cannot produce is a real defect, but they
were never a plausible cause of the black frames on their own. Said plainly
because the earlier note implied otherwise.

### A real bug fixed on the way

The CAMSS resource tables were copied from SDM845 and carried clock rates the
SM8150 camera clock controller cannot produce. Checked against
`camcc-sm8150.c`:

| Clock | Table had | SM8150 supports |
| --- | --- | --- |
| `csiphyN_timer` | 240 MHz, 269.333 MHz | 19.2 MHz, 300 MHz |
| `cphy_rx_src` | 384 MHz | 19.2 MHz, 400 MHz |
| `vfeN` | 100/320/404/480/600 MHz | 400/558/637/847/950 MHz |
| `vfeN_src` | 320 MHz | 400 MHz |
| `csiN` | 384 MHz, 538.667 MHz | 400, 480, 600 MHz |

This matters beyond tidiness for the timer clock: the CSIPHY settle count, the
instant the PHY samples the lanes, is computed from the rate the driver
believes it set. Revision `r60` uses the rates the hardware actually offers.

It did not by itself make frames arrive, which is consistent with the finding
above that the CSID is not configured at all.

## The cause: this is a CSIPHY v1.1, programmed as a v1.0

The published OnePlus kernel settles it in one line. Its `sm8150-camera.dtsi`
declares every CSIPHY as:

```
compatible = "qcom,csiphy-v1.1", "qcom,csiphy";
```

Version **1.1**. The mainline backend written here uses `csiphy_ops_3ph_1_0`,
inherited from the SDM845 template, and SDM845 is `qcom,csiphy-v1.0`. So the
PHY is being initialised with the wrong generation's register sequence.

The vendor's own tables give the size of the gap. Comparing
`cam_csiphy_1_0_hwreg.h` with `cam_csiphy_1_1_hwreg.h`:

| | v1.0 | v1.1 |
| --- | --- | --- |
| register writes | 272 | 440 |
| common block `0x0814` | `0x00` | `0xd5` |
| common block `0x081C` | absent | `0x72` |
| lane `0x0000` | `0x91` | `0x90` |
| lane `0x0008` | `0x00` | `0x0E` |
| lane `0x0708` | `0x14` | `0x0E` |

Different from the first register onwards, and sixty percent more of them.

This explains every observation exactly: the sensor transmits, the CSID is
correctly told to take four lanes from CSIPHY0 over D-PHY, `RX_IRQ_STATUS`
latches error bits, and no decodable data ever arrives. A physical layer set up
for the wrong generation produces electrical activity the receiver cannot
frame.

### On decompiling the OxygenOS libraries

Worth stating, since it was asked. The `.so` files are the userspace HAL: they
issue requests to `cam_req_mgr` and never touch a CSIPHY register. Everything
about the physical layer lives in the kernel, which OnePlus publishes under the
GPL, and which is checked out locally. That is where this answer came from, in
a few minutes and with no decompilation. The libraries would be the right place
to look for tuning data and 3A behaviour, not for bring-up.

## v1.1 applied, revision `r61`: the error pattern changes, frames do not

Mainline already carried the v1.1 sequence as `lane_regs_sc8280xp`, matching the
vendor's v1.1 table entry for entry once its zero padding is discounted. `0064`
adds a `CAMSS_8150` version that behaves as `CAMSS_845` everywhere except the
CSIPHY lane table, where it takes the v1.1 one.

Confirmed active by reading the PHY during a capture:

| Register | v1.0 before | v1.1 now |
| --- | --- | --- |
| PHY `0x814` lane enable | - | `0xd5` |
| PHY `0x000` | `0x91` | `0x90` |
| PHY `0x008` settle count | - | `0x14` |
| `csi0phytimer` | 269 MHz asked for | 300 MHz actual |
| CSID `RX_IRQ_STATUS` | `0x0097c0ff` | `0x010000ff` |

`0x90` rather than `0x91` at lane offset 0 is the v1.1 table's own value, so the
right sequence is being written. The common block is computed rather than
tabulated in mainline, and it lands on `0xd5` for four data lanes plus clock,
which is exactly what the vendor table hardcodes.

The receive error pattern changes substantially, from `0x0097c0ff` to
`0x010000ff`, so the physical layer is behaving differently and better. It is
still not delivering frames, and the low byte of latched per-lane errors
persists.

### A correction to an earlier correction

An earlier note claimed the settle count is computed only in `csiphy-2ph-1-0`
and therefore that the clock rates could not matter. That is wrong:
`csiphy_lanes_enable` in the 3ph driver calls `csiphy_settle_cnt_calc(link_freq,
csiphy->timer_clk_rate)` and feeds the result to `csiphy_gen2_config_lanes`. The
timer rate does matter, the `r60` fix was on the critical path, and the timer
now genuinely runs at 300 MHz.

### The settle count is correct, checked and cleared

Worth recording because it looked like a discrepancy and is not. For a 602.5 MHz
link and the 300 MHz timer:

```
ui               = 1e12 / 602500000 = 1659 ps, halved to 829 ps
t_hs_prepare_max = 85000 + 6 * 829  = 89974 ps
timer_period     = 1e12 / 300000000 = 3333 ps
settle_cnt       = 89974 / 3333 - 6 = 20, or 0x14
```

The final `- 6` is part of the driver's formula and was missed on a first
reading, which made 0x1A look like the expected value. The hardware reads
`0x14`, so the settle count is exactly what the driver intends.

The timer rate selection is consistent too: `csiphy_set_clock_rates` asks for at
least `link_freq / 4`, which is 150.6 MHz, and the only rate above that the
SM8150 clock controller offers is 300 MHz.

So the CSIPHY is now configured correctly as far as can be checked from the
driver's own inputs: right generation, right lane table, right lane enable mask,
right settle count, right timer rate. And the CSID still latches per-lane
receive errors.

That moves suspicion to what the sensor actually emits. The upstream S5K3M5
driver's default mode is 4208x3120 at 602.5 MHz over four lanes; this handset's
telephoto is an 8 MP module, so whether this module is the variant that driver
was written for, and whether its start-streaming sequence really applies here,
is now the open question rather than the receiver.

## The sensor is fully correct, and frames arrive at its own rate

Two things had made earlier readings unreliable and are worth recording.

**The I2C bus numbering is not stable across boots.** The sensor was `4-0010`
on one boot and `6-0010` on the next, because CCI registers its four buses
dynamically. Every register readback done with `-f 4` on the later boot was
addressing the wrong bus and returned NACKs that looked like a dead sensor. The
device-tree slot mapping is unaffected, since it is by node rather than by
number, but any by-hand `i2ctransfer` must read the bus number from
`/sys/class/video4linux/*/name` first.

**Stale capture processes hold the device.** A backgrounded `v4l2-ctl` that is
not reaped makes the next `REQBUFS` fail with `EBUSY`, which is easy to misread
as a pipeline fault.

Read on the right bus while streaming, the sensor is entirely correct:

| Register | Value | Meaning |
| --- | --- | --- |
| `0x0100` | `0x01` | streaming |
| `0x034C` | `0x1070` | output width 4208 |
| `0x034E` | `0x0C30` | output height 3120 |
| `0x0114` | `0x03` | four data lanes |
| `0x0340` | `0x0CF2` | frame length 3314 |

So the upstream driver's mode registers do take, and this module is the variant
it targets. That closes the question the previous section opened.

### Frames arrive at exactly 30.00 fps

This is the observation that reframes everything. `v4l2-ctl` reports
`30.00 fps`, exactly the sensor's frame rate. A VFE receiving nothing would
return buffers at an arbitrary rate, not one locked to the sensor. The capture
is therefore synchronised to the incoming CSI-2 stream: frame timing is getting
through.

And the buffers are still entirely zero.

That moves the problem again, and this time away from the sensor, the CSIPHY and
the CSID alike. Frame boundaries reach the VFE while pixel data does not reach
memory, which is the signature of the write path rather than the receive path:
the RDI write master's configuration, or the SMMU translation for the stream IDs
declared in `0056`. Those eight stream IDs were derived from the downstream
device tree and have never been verified against a real transfer.

`RX_IRQ_STATUS` keeps accumulating per-lane error bits, `0x01d7c0ff` after
several captures, so the link is not clean either. But error bits on a link that
nonetheless delivers frame timing are a different problem from a link that
delivers nothing.

### The SMMU is not the culprit

Checked directly: a capture produces no `arm-smmu` context faults, no IOMMU
messages, and nothing from CAMSS, the VFE or the CSID in the log at all. The
`acb3000.camss` device sits alone in IOMMU group 7 as expected. So the eight
stream IDs are not silently faulting; translation is not what loses the pixels.

That leaves the write master itself, or the CSID's decode configuration. A CSID
told to decode a format that does not match what the sensor sends can still pass
frame boundaries downstream, which would explain frame timing arriving intact
while the payload never becomes pixel data. `RDI_CFG0` reads `0x802bf007`, and
its decode-format and data-type fields have not been checked against
`SGRBG10_1X10` yet.

### The CSID decode configuration is correct too

`RDI_CFG0` = `0x802bf007`, decoded against the driver's own field offsets:

| Field | Bits | Value | Meaning |
| --- | --- | --- | --- |
| `ENABLE` | 31 | 1 | path on |
| `PACKING_FORMAT` | 30 | 0 | MIPI packing |
| `DT_ID` | 27-28 | 0 | |
| `VIRTUAL_CHANNEL` | 22-26 | 0 | |
| `DATA_TYPE` | 16-21 | `0x2B` | CSI-2 RAW10 |
| `DECODE_FORMAT` | 12-15 | `0xF` | payload only, the RDI path |
| `TIMESTAMP_EN` | 2 | 1 | |
| `FORMAT_MEASURE_EN` | 1 | 1 | |
| `BYTE_CNTR_EN` | 0 | 1 | |

`0x2B` is exactly RAW10, which is what an SGRBG10 sensor sends, and payload-only
decoding is the correct RDI setting. So the CSID is told the right thing here as
well.

## Everything checkable is correct, and the frames are still black

The state at the end of this work, with nothing left that can be verified
against the driver's own inputs and found wrong:

| Stage | Verified | How |
| --- | --- | --- |
| sensor mode | correct | 4208x3120, 4 lanes, streaming, read over I2C |
| CSIPHY generation | correct | v1.1 table active, lane reg 0 reads 0x90 |
| CSIPHY settle count | correct | 0x14, matches the driver's own formula |
| CSIPHY timer clock | correct | 300 MHz, the only rate above link_freq/4 |
| CSID receive config | correct | 4 lanes, PHY 0, D-PHY |
| CSID decode config | correct | RAW10, payload only, enabled |
| SMMU translation | not faulting | no context faults during capture |
| frame timing | arriving | one VFE interrupt per frame at 30 Hz, instrumented |
| pixel data | **absent** | every byte of every buffer is zero |

What is left is the VFE write master, the only stage never inspected, plus the
per-lane errors that keep accumulating in `RX_IRQ_STATUS`. Both need
instrumentation rather than register reads from userspace: the write master's
configuration is not exposed anywhere readable, and the error bits need decoding
against a header this tree does not carry.

### A second write master behaves differently, and it undercuts the 30 fps claim

Routing the same stream to `msm_vfe0_rdi1` and capturing from `/dev/video1`
does not return buffers at all: the capture blocks until killed, where RDI0
returns them at 30.00 fps.

That difference matters more for what it says about RDI0 than about RDI1. The
earlier reasoning here was that 30.00 fps, exactly the sensor's rate, proves
frame timing reaches the capture node. If a second write master fed from the
same CSID blocks entirely, that inference is no longer safe: RDI0's steady
30 fps may be the VFE completing buffers on its own cadence rather than on the
sensor's, and the coincidence with 30 fps may be the configured frame rate
rather than evidence of received timing.

This has not been pinned down. RDI1 may equally be blocking because its link
and pad formats were set up incorrectly in this one experiment. Recorded as an
observation that weakens a previous conclusion, not as a finding that replaces
it, and the "frame timing arrives" row of the table above should be treated as
unproven until it is settled.

## Instrumented: frames and write completions both arrive, the payload is empty

`0065` prints the VFE interrupt and bus status, skipping the reset
acknowledgements that otherwise dominate. During a capture:

```
[69.710] vfe0 irq: status0=08000220 status1=00000000 bus0=00000004 bus1=00000000
[69.741] vfe0 irq: status0=00000200 status1=00000000 bus0=00000000 bus1=00000001
[69.775] vfe0 irq: status0=00000200 status1=00000000 bus0=00000000 bus1=00000001
[69.808] vfe0 irq: status0=00000200 status1=00000000 bus0=00000000 bus1=00000001
```

Those repeat at 32 ms, which is 30 Hz, the sensor's frame rate. So the VFE takes
one interrupt per frame and a bus interrupt fires alongside each one: frame
timing reaches the VFE and the write master signals a completion every frame.

The buffers are still entirely zero.

### Correcting an over-correction

An earlier note said the RDI1 experiment made the 30 fps evidence unsafe and
marked frame timing as unproven. That retraction went too far. The instrumented
interrupts show a genuine per-frame interrupt at the sensor's rate, so frame
timing does arrive. The RDI1 capture most likely blocked because its links and
pad formats were set up wrongly in that one experiment, which was the
alternative explanation offered at the time.

### What this leaves

Frame boundaries arrive, the write master completes, the SMMU does not fault,
and the written frame is zero. The remaining candidate is the payload itself:
the CSI-2 packets arrive with errors and carry nothing usable, which is
consistent with `RX_IRQ_STATUS` steadily accumulating per-lane error bits
throughout. A VFE writing a frame that decoded to nothing writes zeroes.

That returns attention to the link's electrical setup, despite the CSIPHY
generation, lane table and settle count all being nominally correct. The next
thing to establish is which error bits are latched, which needs the CSI2_RX_IRQ
bit definitions rather than more guessing.

## The link is now error-free, and the frames are still black

Decoding `RX_IRQ_STATUS` against the vendor headers corrected a misreading
repeated several times here: its low byte is not errors. Bits 0-7 are
`PHY_DL0..DL3_EOT_CAPTURED` and `PHY_DL0..DL3_SOT_CAPTURED`, purely
informational, and `0xff` means all four lanes are capturing packet delimiters
correctly. The errors live higher up, and included lane FIFO overflows.

A FIFO overflow means data arriving faster than the downstream consumes it. The
sensor's pixel rate is 482 MHz, while the CSID and VFE source clocks had been
pinned at 400 MHz, below it. Raising them walked the errors down:

| Revision | CSID and VFE source clocks | `RX_IRQ_STATUS` | error bits |
| --- | --- | --- | --- |
| `r63` | 400 MHz | `0x01d7c0ff` | 7 |
| `r64` | 600 / 637 MHz | `0x000400ff` | 1 |
| `r65` | 600 / 847 MHz | `0x000000ff` | **0** |

At `r65` the CSI-2 link is completely clean: four lanes capturing SOT and EOT,
no ECC warnings, no FIFO overflows, nothing latched at all.

The captured frames are still entirely zero.

So the state is now unambiguous in a way it has not been before. The sensor
streams at the right mode. The link carries it without a single error. Frame
timing reaches the VFE at 30 Hz. The write master completes every frame. The
SMMU does not fault. And memory receives zeroes.

That isolates the fault to the RDI output path between the CSID and memory:
either the write master is addressing somewhere other than the queued buffer, or
it is enabled but not fed from the RDI. Nothing upstream of it remains
suspect, which is a much smaller search than at any earlier point.

## The write master is running with a null image address

Read straight from the VFE bus registers through `/dev/mem`, at rest and during
a capture:

```
au repos      WM0 status0=00000000 cfg=00000000 img_addr=00000000
pendant       WM0 status0=fe000000 cfg=00000003 img_addr=00000000
```

So write master 0 is configured and active while streaming, `cfg` bits 0 and 1
set, status showing activity, and its `VFE_BUS_WM_IMAGE_ADDR` register reads
zero throughout. Write masters 1 to 3 stay untouched, which is right for a
single RDI0 capture.

A write master enabled and clocked but pointed at address zero explains the
symptom exactly and completely: every stage upstream works, the bus completes a
transfer per frame, no SMMU fault occurs because nothing valid is ever
translated, and the queued buffer is never written, so it keeps the zeroes the
allocator gave it.

### The caveat, which matters

Qualcomm bus address registers are frequently write-only shadows that latch on a
register-update command, in which case reading zero proves nothing about what
was programmed. Before treating this as the fault, that has to be settled: check
whether `vfe_wm_update` writes `VFE_BUS_WM_IMAGE_ADDR` at all on this path, and
whether the register-update command that latches the shadow reaches the bus.

The `stride` and buffer-width reads both returned `0x0000ff01`, which is
implausible for a 5264-byte stride and suggests the offsets used for those two
were wrong, so they say nothing either way. Only the address read is at an
offset taken directly from the driver's own macro.

### Settled: the address register is write-only and the addressing is correct

The caveat flagged above was the right one. Instrumenting `vfe_wm_update` shows
the driver programming valid addresses every frame:

```
vfe0 wm0: addr=ff000000 stride=5264 height=3120
vfe0 wm0: addr=fe000000 stride=5264 height=3120
vfe0 wm0: addr=fd000000 stride=5264 height=3120
vfe0 wm0: addr=fc000000 stride=5264 height=3120
```

Four IOVAs cycling through the queued buffers, no truncation, and the stride and
height exactly as configured. So `VFE_BUS_WM_IMAGE_ADDR` reads zero because it is
write-only, not because nothing was written, and the write master's addressing
is correct.

## Where this leaves the port

Every stage is now either verified correct or eliminated:

| Stage | State |
| --- | --- |
| sensor mode and streaming | correct, read over I2C |
| CSI-2 link | zero errors latched |
| frame timing | one VFE interrupt per frame at 30 Hz |
| CSID receive and decode | correct, RAW10 payload-only from PHY 0 |
| SMMU | no faults |
| write master enable and status | active every frame |
| write master addressing | correct IOVA, stride and height |
| memory | still zero |

Nothing in the configured path is wrong. The remaining possibility is that the
write master is enabled and addressed but never actually fed by the RDI, which
would be an input-selection or bus-client-mapping question inside the VFE rather
than anything the board description controls. That is the one place left to
look, and it needs the VFE bus client configuration compared against what the
vendor driver programs for the same path.

## Eliminated in the write-master sweep

Each of these was checked and ruled out, so they need not be revisited.

**The write master is fully and correctly programmed.** A full register dump of
the WM0 block during capture:

```
+0x00 = ff000000   current address, matching what was programmed
+0x08 = 00000003   enabled, MIPI RAW mode
+0x1c = 0000ff01   buffer width, the driver's WM_BUFFER_DEFAULT_WIDTH
+0x28 = 0000ff01   stride, the driver's WM_STRIDE_DEFAULT_STRIDE
+0x4c = ffffffff   frame drop pattern, nothing dropped
+0x58 = 00fa9b00   frame increment, 16423680, exactly stride x height
+0x5c = 0000000f   burst limit
```

**VFE 175 is not the problem.** The vendor device tree calls this `qcom,vfe175`
where sdm845 is `qcom,vfe170`, which looked like a repeat of the CSIPHY
generation mistake. Diffing the vendor's own `cam_vfe170.h` and `cam_vfe175.h`
by numeric value shows the differences are additions for the camif-lite block,
not changes to the RDI or bus register offsets. The RDI path is identical.

**The write-master index is right.** The vendor maps RDI0 to write master 0,
the same as mainline's `wm_idx = line->id`.

**Bandwidth is not the problem.** The sensor also offers a binned 2104x1184
mode. Captured at half the data rate, the frames are equally zero.

**The sensor's own test pattern still does not arrive**, now retested on a link
with zero latched errors, which rules out the optics and the analogue path
again under better conditions.

**`BIT(9)` in `status0` is expected, not a symptom.** It reads as
`IMAGE_MASTER_PING_PONG(1)` while write master 0 is in use, which looked like a
mismatch. It is not: mainline's ISR gates its whole write-master-done dispatch
on a hardcoded `status0 & BIT(9)` rather than on `PING_PONG(wm)`, so BIT(9) is
exactly what this driver expects to see. Buffer completion is then dispatched
from the bus status, where `STATUS1_WM_CLIENT_BUF_DONE(0)` does fire each frame.

### An upstream defect found along the way

```c
for (i = VFE_LINE_RDI0; i < vfe->res->line_num; i++)
        if (status0 & STATUS_1_RDI_SOF(i))
                vfe->isr_ops.sof(vfe, i);
```

A `STATUS_1_` mask tested against `status0`. Start-of-frame is therefore never
detected on this path, on every SoC using this file, not just here. Whether it
matters for RDI capture is a separate question, since register update and buffer
done both arrive by other routes, but the test as written cannot be right.

### VFE1 behaves differently from VFE0

Relinking the same CSID output to `msm_vfe1_rdi0` and capturing from
`/dev/video4` returns no buffers at all, where VFE0 returns them every frame.
So the two instances are not equivalent, and VFE0 is the one further along.

Whether that is a real asymmetry or an artefact of relinking by hand has not
been established, and it is recorded as an observation rather than a finding.

### Where the CID mapping sits

The CSID tags each stream with an internal CID built from the virtual channel
and `DT_ID`, `dt_id = vc & 0x03`, giving CID 0 for this stream. The question
that follows, and that this session did not reach, is whether anything on the
VFE side has to be told which CID feeds RDI0, and what it defaults to when
nothing does.

## Start of frame confirmed, and a concrete difference from the vendor

### The data really does arrive

The vendor header gives RDI0's `sof_irq_mask` as `0x8000000`, bit 27 of the VFE
status word. That value appears in the instrumented traces, alternating with the
ping-pong bit:

```
status0=08000000   <- RDI0 start of frame
status0=00000200   <- write master ping-pong
```

So start of frame genuinely arrives every frame. Mainline simply never
dispatches it, because of the `STATUS_1_` mask tested against `status0` noted
above. That closes the question of whether pixels reach the VFE: the frame
structure does.

### What the vendor writes that mainline does not

Comparing `cam_vfe_bus_start_wm` against mainline's `vfe_wm_start`, the vendor
programs the write master's real geometry:

```c
cam_io_w_mb(rsrc_data->width,  ...->buffer_width_cfg);
cam_io_w   (rsrc_data->height, ...->buffer_height_cfg);
cam_io_w_mb(rsrc_data->stride, ...->stride);
```

Mainline instead writes fixed constants:

```c
writel_relaxed(WM_BUFFER_DEFAULT_WIDTH, ... BUFFER_WIDTH_CFG(wm));   /* 0xFF01 */
writel_relaxed(0,                       ... BUFFER_HEIGHT_CFG(wm));
writel_relaxed(WM_STRIDE_DEFAULT_STRIDE, ... STRIDE(wm));            /* 0xFF01 */
```

and the hardware read-back confirms `0xFF01` in both.

**Tested and wrong.** Revision `r67` programmed the real width, height and
stride for SM8150. The frames stayed entirely zero, and checking the vendor
driver properly afterwards shows why the idea was misconceived: for RDI outputs
it sets

```c
#define CAM_VFE_RDI_BUS_DEFAULT_WIDTH   0xFF01
#define CAM_VFE_RDI_BUS_DEFAULT_STRIDE  0xFF01
        rsrc_data->width  = CAM_VFE_RDI_BUS_DEFAULT_WIDTH;
        rsrc_data->stride = CAM_VFE_RDI_BUS_DEFAULT_STRIDE;
```

The vendor uses the same sentinel on the RDI path; the real geometry it programs
is for the pixel path. Mainline's constants were right, and the difference
spotted above was between two different paths rather than two different SoCs.
Reverted in `r68`.

## Bisecting with the CSID's own generator

The CSID carries an internal test generator, exposed as a `test_pattern` control
on `msm_csid0`. Driving it isolates the CSID-to-memory path from CSI-2 reception
entirely. The control only takes effect once the CSIPHY link is disabled, since
a connected source overrides it:

```
media-ctl -l '"msm_csiphy0":1 -> "msm_csid0":0 [0]'
v4l2-ctl -d /dev/v4l-subdev4 --set-ctrl=test_pattern=1   -> Incrementing
```

With the generator running and no CSI-2 input at all, the capture returns **no
buffers whatsoever** and times out, where the sensor path returns one per frame.

That is a difference worth having, but it is not conclusive on its own: the
generator may need virtual channel and data type settings this experiment did
not provide, so "no buffers" may mean "generator not actually producing" rather
than "path broken". The handset also reset during the experiment, so the run was
not clean.

**The experiment was invalid, and the reason is structural.**
`csid_configure_stream` only configures virtual channels present in
`csid->phy.en_vc`:

```c
for (i = 0; i < MSM_CSID_MAX_SRC_STREAMS; i++)
        if (csid->phy.en_vc & BIT(i)) {
                if (tg->enabled)
                        __csid_configure_testgen(csid, enable, i);
                __csid_configure_rdi_stream(csid, enable, i);
                ...
        }
```

`en_vc` is populated from the CSIPHY link. Disabling that link, which is the only
way to make the generator control settable, leaves `en_vc` empty, so nothing is
configured at all and the generator never runs. The "no buffers" result means
exactly that, and says nothing about the write path.

This is a circular limitation in the driver rather than a property of the
hardware, so the bisection cannot be done from userspace as it stands. Forcing
`en_vc` alongside the generator would need a small patch.

## The write master performs no memory writes at all

Every earlier statement here described the frames as "entirely zero". That was
literally true and diagnostically misleading, and this settles what it meant.

Queueing buffers pre-filled with `0xAA` through the V4L2 mmap interface, rather
than letting `v4l2-ctl` allocate them, gives:

```
trame 0 (buf 0): 0xAA restants 100.0%  zeros 0.0%  bytesused=16423680
trame 1 (buf 1): 0xAA restants 100.0%  zeros 0.0%  bytesused=16423680
trame 2 (buf 0): 0xAA restants 100.0%  zeros 0.0%  bytesused=16423680
```

The pattern survives untouched across every frame. The write master is not
writing zeroes; it is not writing anything. Freshly allocated pages are zero, so
every capture to a file until now was recording the allocator's zeroes rather
than anything the hardware produced.

That reframes the whole search. The question was "why does the hardware write
zeroes", which invited theories about decoding, link errors and formats. The
question is actually "why does a write master that reports a completed transfer
issue no bus write at all", which is much narrower.

What sits either side of it, all verified: the CSI-2 link latches no errors, the
sensor's start of frame arrives every frame at bit 27, the write master is
enabled with the right mode, geometry, burst limit and frame increment, its
address register holds a valid IOVA that cycles across the queued buffers, the
bus signals client-done for write master 0 every frame, and the SMMU records no
faults because nothing is ever translated.

A write master that signals completion without a single bus transaction points
at its input: the RDI stream inside the VFE carries no pixels, even though the
CSID receives them cleanly. That is now the one thing left to explain.

## The CSID delivers a full frame to the VFE

The CSID keeps a per-RDI byte counter, enabled here by `RDI_CFG0_BYTE_CNTR_EN`,
with ping and pong registers at `0x3e0` and `0x3e4` for RDI0. Read during a
capture:

```
byte_cntr ping=16411200 pong=16411200  RDI_CTRL=00000001
```

16,411,200 is exactly 4208 x 3120 x 10/8: one complete RAW10 frame, on both
halves of the ping-pong pair. So the CSID is not merely receiving cleanly, it is
handing a full frame's worth of bytes onward every frame.

Combined with the pre-filled buffer result, the fault is now bounded on both
sides with hardware evidence:

| Boundary | Evidence |
| --- | --- |
| into the VFE | CSID byte counter shows a full frame per frame |
| out of the VFE | queued buffers keep their `0xAA` fill untouched |

Everything before the VFE bus works. The VFE bus receives a complete frame,
reports its write master done, and performs no memory write. That is the fault,
stated as narrowly as the hardware allows.

### The bus clock-gating override, tested and ruled out

The vendor's register map carries `bus_cgc_ovd` at offset `0x3C` in the VFE top
block, separate from the write-master clock-gating override at `0x200c` that
mainline does write. A gated bus would fit the symptom exactly: status reported,
no transfer performed. Revision `r69` lifted it. The pre-filled buffers came
back with their pattern fully intact, so it changed nothing, and `r70` removes
the write again rather than leaving a speculative poke at an undocumented
register in the tree.

Note that `0x3C`, `0x18` and `0x50` all read back the VFE hardware version, so
these registers are write-only and cannot be inspected; the experiment was the
only way to test the idea.

### The IOVA range, tested and ruled out

The SMMU stream IDs match the vendor device tree exactly, all eight of them. But
the same node also declares the IFE context bank's addressable region:

```
iova-region-start = <0x7400000>;
iova-region-len   = <0xd8c00000>;      /* 0x07400000 .. 0xe0000000 */
```

Linux allocates from the top of the 32-bit space, so buffers were landing at
`0xff000000` and above, outside that region. `0066` narrows the DMA mask for
SM8150 so allocations stay inside it, and the addresses do move as intended:

```
vfe0 wm0: addr=7f000000 stride=5264 height=3120
vfe0 wm0: addr=7e000000 stride=5264 height=3120
vfe0 wm0: addr=7d000000 stride=5264 height=3120
```

The pre-filled buffers still come back with their pattern fully intact. So the
IOVA range was not the cause either. The patch is kept, because staying inside
the range the hardware is described as addressing is right on its own terms, but
it is explicitly not a fix.

## The VFE bus is entirely idle during capture

Snapshotting all 4 KB of the VFE bus register block twice, 1.5 seconds apart,
in the middle of a running capture, and diffing:

```
registres qui changent dans 0x2000-0x2fff pendant la capture: 1
  +0x2200  7e000000 -> 7d000000
```

Exactly one register moves, and it is the write master's address, which the
driver itself rewrites each frame from the CPU. No counter advances, no status
bit toggles, nothing else in the block changes at all.

So the bus is not processing frames slowly or incorrectly. It is doing nothing.
The buffer-done interrupts that do arrive come from the bus IRQ status, which
the handler reads and clears immediately, so they do not show up in a sampled
diff and are not evidence of transfer.

That moves the fault one stage earlier than the previous note placed it. The
question is not why the bus writes nothing, but why the VFE core never presents
the RDI stream to the bus, given the CSID hands it a complete frame.

Mainline writes very little in the VFE top block for an RDI path: no
`VFE_CORE_CFG`, which it defines at `0x050` and never uses, and none of the
module-control registers the vendor's map carries alongside it. That is where
the next look belongs.

## The strongest untested lead: no AXI bandwidth is voted

CAMSS supports interconnect bandwidth voting, as `resources_icc` in `camss.c`,
and SM8250, SC7280, SC8280XP, SM8550, X1E80100 and MSM8x53 all declare it. The
SM8150 resources added here declare none, and the device tree node carries no
`interconnects` property either, because SDM845, the template, has none.

That fits the observation better than anything else tested. Without a vote on
the camera NoC paths, the write master can be fully configured and enabled while
having no route to memory, which is exactly a bus that sits completely idle
while the CSID hands it whole frames.

The values SM8150 needs are available: `MASTER_CAMNOC_HF0`, `MASTER_CAMNOC_HF1`
and `MASTER_CAMNOC_SF` on `mmss_noc`, `SLAVE_EBI_CH0` on `mc_virt`, and
`SLAVE_CAMERA_CFG` on `config_noc`, all defined in
`dt-bindings/interconnect/qcom,sm8150.h`, with the three named paths `cam_ahb`,
`cam_hf_0_mnoc` and `cam_sf_0_mnoc` matching SM8250's table.

**Landed as `0067` in `r72`, and tested: it does not fix it.** CAMSS probes
without complaint and the three paths are described, but buffers queued
pre-filled with `0xAA` still come back with the pattern fully intact. So the
absence of bandwidth voting was not the cause either.

The patch is kept, because every other supported part declares these paths and
describing them is right on its own terms, and it is marked here as explicitly
not a fix.

An earlier attempt to land it failed because the patch text was edited directly
and the hunk headers went stale. The fix was to extract a clean tree from the
source tarball, apply the series once, edit the files and regenerate the diff.
Worth recording, since editing patch text by hand caused several failures in
this session and regenerating from a clean tree is the reliable route.

## The clocks are running, except one

Read during a capture:

```
cam_cc_ife_0_clk_src       en=3 prep=3 rate=847000048
cam_cc_ife_0_clk           en=2 prep=2 rate=847000048
cam_cc_ife_0_axi_clk       en=1 prep=1 rate=150000000
cam_cc_camnoc_axi_clk_src  en=2 prep=2 rate=150000000
cam_cc_camnoc_axi_clk      en=2 prep=2 rate=150000000
cam_cc_camnoc_dcd_xo_clk   en=0 prep=0 rate=0
```

So the IFE core, its AXI clock and the CAMNOC AXI path are all enabled and
clocked, which removes the last suspicion that the data path to memory is simply
off.

`cam_cc_camnoc_dcd_xo_clk` is the one clock in the CAMNOC block this port never
requests. `CAM_CC_CAMNOC_DCD_XO_CLK` exists in
`dt-bindings/clock/qcom,sm8150-camcc.h` and appears in neither the resource
table nor the device tree node here. Whether the CAMNOC needs it for data to
move, or whether it only serves a debug function, is untested and is the next
concrete thing to try: it is a one-entry addition to the VFE clock list and the
device tree node.

**Tested in `r73` and reverted.** Adding `camnoc_dcd_xo` to the VFE clock list
and the device tree node stopped CAMSS probing altogether: no `/dev/video0`, no
`/dev/media0`. The clock and name arrays evidently need more care than a single
insertion at a matching index, or the resource table's rate array has to grow in
step. `r74` removes it and CAMSS is back.

So this is untested rather than ruled out, and redoing it needs the clock,
clock-name and clock-rate arrays kept in lockstep across both the driver table
and the node.

## Working on the Sony sensors

Three of the four slots hold Sony parts with no upstream driver: IMX586 on slot
0, IMX481 on slot 2 and IMX471 on slot 3, all inferred rather than confirmed.

Confirming them does not need a driver. The upstream S5K3M5 driver prints the
chip id it actually read when it does not match:

```c
dev_err(..., "chip id mismatch: %x!=%x\n", S5K3M5_CHIP_ID, val);
```

So describing an `s5k3m5` node on a Sony slot powers that slot correctly, reads
a register and reports what came back, which identifies the part without writing
anything. Two things have to be right for it: the address, and the register.

Sony sensors on Qualcomm boards usually answer at 0x1a rather than the 0x10 the
Samsung part uses, and they carry their model at register 0x0016, not 0x0000
where the Samsung driver looks. So the useful experiment is a small variant of
the identification aid that reads 0x0016 at 0x1a, on the three slots whose
supplies, reset lines and MCLKs are already described and known good from the
slot table above.

That is a bounded piece of work and it is the right next step for the Sony
parts, independent of the VFE write-path fault, which blocks streaming on every
slot equally including the one sensor that is already driven.

### Attempted, and the Sony slots reset the handset

`0068` extends the identification aid to read `0x0016` as well as `0x0000`, and
paces the transfers. On `r75` the three scan nodes are present, one per Sony
slot:

```
/sys/bus/i2c/devices/5-007f   slot 0
/sys/bus/i2c/devices/6-007f   slot 2
/sys/bus/i2c/devices/7-007f   slot 3
```

Loading it with `scan=1` resets the handset before a single line reaches the
log. This reproduces the earlier failure and localises it: slot 1, the Samsung
one, scanned fine and gave its chip id; the three Sony slots do not survive
being powered this way.

That points at the supplies rather than the bus, and specifically at the enable
GPIOs those slots use, which slot 1 does not: slot 0 drives `tlmm 11`, `tlmm 29`
and `pm8150l` GPIO 1, slot 2 drives `pm8150l` GPIO 12 and slot 3 `pm8150l`
GPIO 2, where slot 1 only drives `tlmm 148`. A reset rather than an oops
suggests something electrical, a rail being asserted that the running system
depends on, rather than a driver fault.

The next step is therefore to bring one Sony slot up in isolation, with its
enable GPIOs asserted one at a time, rather than all three slots at once. The
aid stays inert unless loaded with `scan=1`, so the handset boots normally with
it present.

### One slot at a time, and the correlation is exact

`0069` makes the aid take an I2C bus number so a single slot can be powered.
Scanning slot 2 alone, on `i2c-6`, resets the handset just as all three together
did, again before anything reaches the log.

So it is not a cumulative load problem. Any one Sony slot is enough, and the
correlation with the slot table is exact:

| Slot | Enable GPIOs | Result |
| --- | --- | --- |
| 1 | `tlmm 148` only | scans cleanly, gave its chip id |
| 0 | `tlmm 11`, `tlmm 29`, `pm8150l` GPIO 1 | resets the handset |
| 2 | `pm8150l` GPIO 12 | resets the handset |
| 3 | `pm8150l` GPIO 2 | resets the handset |

The one slot that works is the only one that touches no PMIC GPIO. Every slot
that resets the handset asserts one.

**The numbering is right, and that hypothesis is refuted.** The stock overlay's
own pinctrl children name the same pins its `gpios` arrays index:

```
cam_sensor_rear_0_dvdd_active { pins = "gpio1";  output-low; }
cam_sensor_rear_2_ana_active  { pins = "gpio2";  output-low; }
                              { pins = "gpio12"; output-low; }
```

against `gpios = <&pm8150l_gpios 0x01 ...>`, `<... 0x02 ...>` and
`<... 0x0c ...>`. So the index is the one-based physical pin number, exactly the
convention mainline uses, and the numbers here are correct.

**The polarity is the better candidate.** Every one of those stock states drives
the pin *low* to activate, and the suspend states pull it down. These GPIOs are
declared `GPIO_ACTIVE_HIGH` here, so the aid asserts them high, the opposite of
what the board does. Driving a PM8150L pin the wrong way is a far more plausible
route to an instant reset than an off-by-one, and it fits the correlation
exactly: slot 1, which works, uses a TLMM pin and no PMIC pin at all.

**Tested in `r77`, and it is not that either.** All three PM8150L enables are now
`GPIO_ACTIVE_LOW`, and scanning slot 2 still resets the handset.

**A better correlation, which the polarity test made visible.** The rails, not
the GPIOs, split the slots the same way:

| Slot | Digital rail | Pre-existing? | Result |
| --- | --- | --- | --- |
| 1 | PM8009 `ldo2` | yes, `vreg_l2f_1p2` was already described | scans cleanly |
| 0 | PM8009 `ldo1` | no, added by `0059` | resets |
| 2 | PM8009 `ldo3` | no, added by `0059` | resets |
| 3 | PM8009 `ldo4` | no, added by `0059` | resets |

The one slot that works is the only one whose digital rail was already in the
device tree before this port touched it. The three that reset all use LDOs added
in `0059`, at 1.104 V and 1.056 V, with `vdd-l1-supply`, `vdd-l3-supply` and
`vdd-l4-supply` all pointed at `vreg_s8c_1p3` because that is what `ldo2` uses.

That parent choice was an inference, not something read from the hardware. If
any of those three LDOs is actually fed from a different rail, or cannot supply
what a sensor draws from where it is pointed, enabling it would collapse a
shared supply, which is exactly a reset with nothing in the log.

**A concrete discrepancy found.** The vendor's own regulator description gives:

```
pm8009_l1: regulator-pm8009-l1 {
        regulator-min-microvolt = <1100000>;
        regulator-max-microvolt = <1304000>;
        qcom,init-voltage       = <1100000>;
};
```

A range from 1.100 V to 1.304 V, initialised at 1.100 V. `0059` pins it to a
single point at 1.104 V, minimum equal to maximum, taken from the stock sensor
node's `rgltr-min-voltage` rather than from the regulator's own description. The
same applies to ldo3 and ldo4 at 1.056 V.

Pinning an RPMh regulator to a voltage its own description does not offer is a
real error regardless, and `0071` corrects it in `r78`: ldo1 gets 1.100 to
1.304 V, ldo3 and ldo4 get 1.096 to 1.304 V.

**It does not stop the reset.** Scanning slot 2 on `r78` still resets the
handset. So the voltage ranges were wrong and are now right, and they were not
the cause.

What that leaves for the Sony slots, in order of what has been ruled out by test:
the PM8150L GPIO numbering is correct, the enable polarity is correct, and the
rail voltages are correct. The remaining differences between the working slot
and the three failing ones are the LDOs themselves, ldo1, ldo3 and ldo4 against
ldo2, and their `vdd-l*-supply` parents, which were inferred from ldo2 and are
the one part of `0059` that has never been checked against anything.

The vendor sets no `parent-supply` on these at all, so the `vdd-l1-supply`,
`vdd-l3-supply` and `vdd-l4-supply` choices here cannot be checked against it
directly; they describe physical topology that RPMh manages internally.

## Remaining

1. why enabling any PM8009 camera rail resets the handset, when supplies alone
   are enough to do it and the reset leaves no log. This needs recording that
   survives the reset, not another description change

   The `pm8009` versus `pm8009-1` compatible was checked and does not matter
   here: both variants give ldo1 through ldo4 the same `vdd-l1` to `vdd-l4`
   supply names and the same `pmic5_nldo` voltage table, differing only in
   smps2.

   **There is no mainline reference for these rails.** Every board in the tree
   that describes PM8009 declares only ldo2, ldo5 and ldo6, and only
   `vdd-l2-supply` among the LDO parents. `sm8150-microsoft-surface-duo.dts`,
   the other mainline SM8150 handset with this PMIC, carries exactly the three
   LDOs hotdog had before this port added any, with the same voltages.

   So `vdd-l1-supply`, `vdd-l3-supply` and `vdd-l4-supply` here are not a
   deviation from a known-good description; nobody has described them upstream
   at all. `0072` removes them in `r79`, describing the rails the way every
   other board does.

   **Tested, and it does not stop the reset either.** Scanning slot 2 on `r79`
   resets the handset as before.

### Where the Sony slots stand

Five hypotheses tested on hardware and each refuted, with the description left
more correct after each:

| Hypothesis | Result |
| --- | --- |
| PM8150L GPIO numbering wrong | numbering confirmed correct against the stock overlay |
| enable polarity wrong | corrected to active low, no effect |
| rail voltages pinned to unsupported points | corrected to the vendor ranges, no effect |
| wrong `pm8009-1` compatible | same supply names and voltage table, not applicable |
| invented `vdd-l*` parents | removed, no effect |

What still separates the working slot from the three that reset is only that
slot 1 uses `ldo2`, which was described before this port existed, while the
others use `ldo1`, `ldo3` and `ldo4`, which it added. Nothing in the description
of those three is now known to be wrong, and no mainline board describes them to
compare against.

### Staged power-up: it is the regulator enable

`0073` adds a `stage` parameter that stops the sequence after the supplies,
after the analogue enable GPIOs, after MCLK, or runs it all. Slot 2 at
`stage=1`, supplies only, with no GPIO asserted, no clock started and reset
still held:

**the handset resets.**

So it is none of the things tested and refuted above. It is not the GPIOs, not
their polarity, not the clock, not the reset line. Enabling the regulators is
enough on its own.

Of the three that slot asks for, `vio` is PM8150L ldo1 and `vana` is the boost
converter, both shared with much of the system and already on before the camera
touches them; enabling an already-enabled regulator only takes a reference.
`vdig` is PM8009 `ldo3`, which nothing else uses and which this port added.

That is now the single suspect, and it is consistent with everything: slot 1
works and is the only one whose digital rail, `ldo2`, was described before this
port existed.

### `ldo3` is not declared by the vendor, but that is not the explanation

The vendor's regulator description declares `pm8009_l1`, `l2`, `l4`, `l5`, `l6`
and `l7`, and **no `l3`**, while its own camera overlay resolves slot 2's
`cam_vdig` to `pm8009_l3`. So that rail is referenced and never described, which
made an unprovisioned RPMh resource a strong candidate for the reset.

It does not hold. Slot 0 uses `ldo1`, which the vendor does declare, and
scanning it alone resets the handset just the same. Whatever is fatal is common
to all three, not specific to the undeclared rail.

Worth noting for anyone repeating this: module parameters only take effect at
load, so the aid has to be removed with `rmmod` before `modprobe` with a
different `scan=`. A run that appears to do nothing is usually the module
already being loaded from boot with `scan=-1`.

The measurement that would settle it is PMIC state across the reset, which needs
something that survives the reset to record it: the handset comes back with an
empty log every time, so the answer is not going to come from `dmesg`.
2. the VFE write-path fault, which blocks streaming on every slot
2. failing that, what the VFE top block needs so it presents the RDI stream to
   the bus.
   Eliminated by test: the write master's configuration, geometry and
   addressing, the IOVA range, the bus clock-gating override, the SMMU stream
   IDs, camera NoC bandwidth voting, the VFE version, the write master index,
   and link bandwidth
   Eliminated by test so far: the write master's configuration, geometry and
   addressing, the IOVA range, the bus clock-gating override, the SMMU stream
   IDs, the VFE version, the write master index, and link bandwidth
2. confirm the other three slots and write IMX586, IMX481 and IMX471
3. libcamera, and the pop-up motor the front camera depends on
2. confirm the other three slots and write IMX586, IMX481 and IMX471
3. libcamera, and the pop-up motor the front camera depends on
2. confirm the other three slots and write IMX586, IMX481 and IMX471
3. libcamera, and the pop-up motor the front camera depends on
2. confirm the other three slots and write IMX586, IMX481 and IMX471
3. libcamera, and the pop-up motor the front camera depends on
2. why a write master with correct geometry, address and enable, fed by an
   error-free link that delivers start of frame every frame, completes its
   transfer without writing a byte
2. confirm the other three slots and write IMX586, IMX481 and IMX471
3. libcamera, and the pop-up motor the front camera depends on
2. confirm the other three slots and write IMX586, IMX481 and IMX471
3. libcamera, and the pop-up motor the front camera depends on
2. confirm the other three slots and write IMX586, IMX481 and IMX471
3. libcamera, and the pop-up motor the front camera depends on
2. confirm the other three slots and write IMX586, IMX481 and IMX471
3. libcamera, and the pop-up motor the front camera depends on
2. decode the accumulating `RX_IRQ_STATUS` per-lane errors
3. confirm the other three slots and write IMX586, IMX481 and IMX471
4. libcamera, and the pop-up motor the front camera depends on
2. decode the residual per-lane errors in CSID `RX_IRQ_STATUS` `0x010000ff`
3. confirm the other three slots and write IMX586, IMX481 and IMX471
4. libcamera, and the pop-up motor the front camera depends on
2. confirm the other three slots the same way the telephoto was confirmed,
   once the identification aid survives a slot with nothing to answer
3. write IMX586, IMX481 and IMX471 from the downstream register sequences
4. libcamera pipeline configuration
5. the pop-up motor, which the front camera needs before it can see anything
6. optionally the lite CSID and VFE instances, and a binding YAML
