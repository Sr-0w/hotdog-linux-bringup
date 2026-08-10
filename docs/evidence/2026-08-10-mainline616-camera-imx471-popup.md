# Sony IMX471 front camera and pop-up position sensing

Date: 2026-08-10

## Result

Kernel revision `r112` identifies the physical front sensor as a Sony IMX471
on CCI1 master 0 (`i2c-6`) at address `0x10`. The driver uses MCLK2 at
19.2 MHz, the OxygenOS-derived supply sequence, a four-lane D-PHY link to
CSIPHY2, and a 1748x1748 RAW10 mode. A direct boot binds `imx471 6-0010`,
links it immutably to `msm_csiphy2`, and makes it the fourth camera reported by
libcamera.

No front-camera stream was started while the module was retracted. Sensor
identification and media-graph registration do not require an optical path,
but capture validation does. The pop-up must first be raised under bounded,
position-aware motor control.

Kernel revision `r113` adds a small IIO driver for the two MagnaChip MXM1120
Hall sensors used by that mechanism. It enables QUPv3 SE1 I2C in PIO mode and
describes only the sensors and their supplies. It deliberately does not
describe the motor GPIOs, boost output or PWM, so this revision cannot move the
camera module.

The exact r113 image was written to `boot_b`, and the complete 96 MiB partition
readback matched before a normal Linux reboot. The resulting direct-mainline
boot reports:

```text
boot ID: 4b13a9d4-c343-4aa4-abf9-9b6004a6566c
kernel: Linux 6.16.0-sm8150 #114-oneplus-hotdog-mainline616
slot: _b, Successful=1, Bootable=1
module: mxm1120
camera-popup-up:   -13 to -14
camera-popup-down: -369 to -370
```

Twenty readings at 100 ms intervals stayed within those one-count ranges. This
is the accepted closed-position baseline for the next bounded motor test.

## Hardware mapping

| Function | Mainline resource |
| --- | --- |
| Hall bus | QUPv3 SE1, `i2c1`, 100 kHz PIO |
| Upper Hall sensor | MXM1120 at `0x0c` |
| Lower Hall sensor | MXM1120 at `0x0d` |
| Hall analog supply | PM8150L L7, `vreg_l7c_3p0` |
| Hall I/O supply | PM8150L L8, `vreg_l8c_1p8` |
| Closed upper baseline | `-13..-14` raw |
| Closed lower baseline | `-369..-370` raw |

The driver checks device ID `0x9c`, selects 10-bit 80 Hz operation and exposes
polling reads through standard IIO sysfs. Interrupt thresholds are deferred
until both mechanical endpoints have been measured.

## Bounded motor preflight

Kernel revision `r114` adds the DRV8834 board resources and a deliberately
limited preflight driver. The OxygenOS implementation defines a nominal upward
course of `1380 * 32 = 44160` microsteps and accepts the open endpoint when the
absolute upper Hall reading reaches `150`. Mainline retains `44160` only as a
future hard ceiling.

The first command emits exactly `320` individual STEP edges in 1/32 mode. It
is accepted only from the measured closed region (`abs(down) >= 300` and
`abs(up) < 50`), may run only once per module load, and always disables STEP,
SLEEP, mode and BOOST afterward. This avoids relying on scheduler timing or a
free-running PWM for the first physical movement.

Revision `r114` booted directly but exposed an integration error before any
actuation: successful `iio_read_channel_raw()` calls return `IIO_VAL_INT`, not
zero. Revision `r115` normalizes those successful reads. The corrected module
was loaded from the validated r115 package into the ABI-identical running
kernel, and the one-shot preflight completed with:

```text
before: hall_up=-14 hall_down=-370
after:  hall_up=-14 hall_down=-365
20 samples: hall_up=-12..-14 hall_down=-364..-365
driver: used=1 error=0 microsteps=320
```

The decrease in lower-sensor magnitude is consistent with upward travel away
from the closed endpoint. Ten full steps therefore produce approximately five
raw Hall counts on this mechanism. The upper Hall remains nearly unchanged at
this early position, as expected.

## Full travel and front-camera capture

Revisions `r116` through `r119` extend the bounded preflight into a complete
opening course. The final implementation preserves the OxygenOS limit of
`44160` microsteps, verifies the initial direction after `320` microsteps,
samples both Hall sensors every `64` microsteps and leaves every motor control
inactive after completion. The accepted full opening used exactly `44160`
microsteps and ended at:

```text
hall_up=-349..-350
hall_down=-11..-12
endpoint=1
error=0
```

With the module physically open, Plasma Camera selected the fourth libcamera
camera and produced a correctly exposed `1748x1740` JPEG from the IMX471. The
capture was inspected locally for technical validation only. No captured image
or image fingerprint is retained in this repository.

Libcamera package revision `r9` adds the IMX471 static properties, the Sony
`1024 / (1024 - code)` analogue-gain conversion, a 1.0 micrometre pixel size,
RAW10 black level `4096`, two-frame exposure/gain/blanking delays and a simple
IPA tuning profile. After installation, libcamera uses
`/usr/share/libcamera/ipa/simple/imx471.yaml` and no longer emits missing sensor
properties, helper, tuning or control-delay warnings.

A metadata-only 180-frame run completed without writing image data. It held
approximately 90 fps at the native raw pipeline size, selected four exposure
times from `7429` through `8352` microseconds, and selected 43 distinct analogue
gains from `1.0x` through `14.222222x`. This validates automatic exposure and
gain control as well as the two-frame delayed-control path.

The first direct test after Plasma Camera had released the graph exposed a
separate CAMSS recovery limitation: CSID/VFE reset timeouts persisted across a
`qcom_camss` module reload. One normal software reboot restored the graph, all
four cameras enumerated again, and the 180-frame IMX471 run then completed.

Revision `r120` adds the symmetric Hall-terminated closing course. Its initial
direction check proved that only the upper Hall sensor changes measurably near
the open endpoint, so the guard rejects motion only when neither sensor moves
in the expected direction. Starting after that bounded 320-microstep check, the
accepted closing command stopped after another `42112` microsteps:

```text
hall_up=-338 -> -12
hall_down=-12 -> -368
endpoint=1
error=0
```

The course stopped on the measured closed thresholds before the `44160`
microstep hard ceiling and powered the motor down. Automatic opening before an
IMX471 stream and automatic closing after release remain to be hardware-tested.

Revision `r121` implements that lifecycle through a generic PM domain owned by
the pop-up motor driver and referenced by the IMX471 device-tree node. The
sensor's existing runtime-PM acquisition now opens the mechanism before sensor
resume and streaming, while its final runtime-PM release closes it after sensor
suspend. Opening and closing are idempotent at their measured Hall endpoints;
a failed automatic opening also attempts the bounded closing course before
returning the error. The provider starts logically powered so attaching and
probing the I2C sensor cannot raise the mechanism during boot. Its first idle
transition establishes the physically closed state.

The driver object, device tree, binding and complete pmaports package build all
pass offline validation. Hardware lifecycle validation is pending because the
handset stopped enumerating after a host-side USB recovery attempt. No motor
command was issued during that outage. The mechanism must be treated as
physically open until fresh Hall readings prove otherwise.

## Production-speed automatic lifecycle

Revisions `r122` through `r131` replace the diagnostic GPIO stepping path with
the PM8150L LPG channel and match the downstream DRV8834 sequence. The final
configuration uses the closest periods that the LPG can represent exactly:
`105000` ns for the 960-microstep slow ramp and `13125` ns for the remainder of
the course. It keeps the motor boost rail enabled as OxygenOS does, stages each
period change while PWM output is disabled, and retains the Hall endpoints and
`44160`-microstep hard limit.

The first production-speed tests exposed a Hall dead zone at both mechanical
endpoints. A guard immediately after the slow ramp incorrectly reported a
stall even though the downstream driver accelerates unconditionally at that
point. Revision `r131` permits a bounded `3200`-microstep fast probe when the
slow ramp has not changed either Hall sensor, then requires measured progress
before allowing the rest of the course. A real obstruction is therefore
stopped after only 4160 microsteps, while endpoint backlash can be cleared.

The corrected module was first tested live against the ABI-identical running
kernel. It retracted a module that the previous guard had left open, then
completed an opening followed only 200 ms later by a closing:

```text
open:  steps=30445 endpoint=1 error=0 Hall -13/-351 -> -316/-10
close: steps=27017 endpoint=1 error=0 Hall -317/-11 -> -12/-357
```

The `r131` package and generated AVB boot image were then installed to
`boot_b`; the full 96 MiB partition readback matched. Direct boot build `#132`
enumerated a clean media graph with all four cameras. A 60-frame libcamera run
on IMX471 sustained approximately 90 fps and exercised the generic PM-domain
lifecycle without any explicit motor command:

```text
open:  steps=31817 endpoint=1 error=0 Hall -12/-357 -> -311/-10
close: steps=32731 endpoint=1 error=0 Hall -310/-11 -> -12/-359
automatic_open_count=1 automatic_close_count=2
```

This validates automatic extension before front-camera streaming and automatic
retraction when the camera is released, including the application camera-switch
path. The movement speed I validated matches the OxygenOS behavior closely.

## Artifacts

| Artifact | SHA-256 |
| --- | --- |
| `linux-oneplus-hotdog-mainline616-6.16.0-r112.apk` | `09f421ff7cb10bdbb359b08b482f60266a0f8afd2e00d3dcfee7513f537d6927` |
| r112 `boot.img` | `1cc8b74f3ee444fe98d830146cd8f318befd40b04f94823f423a67361fc56ac4` |
| `linux-oneplus-hotdog-mainline616-6.16.0-r113.apk` | `01ab71f6f191f7039a211a248783766efb69f390ec59909af5bfda1d773af6a9` |
| r113 `boot.img` | `5c92692ae9666d5c5eeb3023a35ff77ab15aad3240f5dad9dcb0a44ffac34949` |
| r113 kernel | `efd1a3d804eb3974f5f4132234a271c24f7335aa14b45576f7055883350aae68` |
| r113 DTB | `4c21ccc5ca9809bf39e1d34d0870c2ae9ffe75b77deaf6c8c5c8d4674be8c66f` |
| r113 initramfs | `d81f113caf74122a20063677c6381f6d2fad144209dc67561ccc9ec203738e08` |
| `linux-oneplus-hotdog-mainline616-6.16.0-r114.apk` | `b48ca941c1ed6095468d2e1504f7d2548f5ed85ebbcf8a06bfa655f7c86b0d97` |
| r114 `boot.img` | `54dcc1bc3c176148f5e774bdc5aa3cbb65e0d546546d24e4519a4df1aee3ad6a` |
| r114 kernel | `8ae83ada5525e8a45e1eda99fddbacede0a0423cc7417859de38a0254b3318ae` |
| r114 DTB | `b6a800f884be0a90e76b681a987e1ed58ad22db517f38dee12c63baa74597f1a` |
| `linux-oneplus-hotdog-mainline616-6.16.0-r115.apk` | `7c38148d868e6ae07217c7a3ffc73da208428729db3970126dcb9ccb3695f774` |
| `linux-oneplus-hotdog-mainline616-6.16.0-r120.apk` | `741fd83e5c5e55748d07669a2453ffa7e592977adcefa073616a49cbf0bb2dfc` |
| `linux-oneplus-hotdog-mainline616-6.16.0-r121.apk` | `e6144844244e0bf7e5df1d7755c8e7d4cfd22334ee1494529cd34f8b55c623c7` |
| `linux-oneplus-hotdog-mainline616-6.16.0-r131.apk` | `0f78808bba1b1aa2845b0550e6278ed69f4fd8fdc2d3d5e04b55aed003e2a03a` |
| r131 `boot.img` | `4f4c5ab8014edf630284de1122450777473f37538e0e7aae3b061595155da8e1` |
| `libcamera-99990.7.2-r9.apk` | `0ea39a98a3a67967ab2c6ce25ab17db69758e6807ffb17412d171b8b022fc82f` |
| `libcamera-ipa-99990.7.2-r9.apk` | `9f1dc9b00b06ea5d0bcb84a835f0241ed53be0de6ebf2c66c7cbb143f29ba3bf` |
| `libcamera-tools-99990.7.2-r9.apk` | `5a43b39a954662a33d1e2e0f1d6c666ba8763197e030a522426c609d750aab32` |

## Next step

Repeat failed-start, process-abort and suspend tests while verifying that the
mechanism never remains raised after camera ownership ends. Then tune automatic
exposure and white balance convergence for IMX471 and validate the application
camera-switch lifecycle alongside the remaining three sensors.
