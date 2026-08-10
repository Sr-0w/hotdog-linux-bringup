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
free-running PWM for the first physical movement. Hardware actuation is still
pending; no claim about direction or Hall slope is made yet.

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

## Next step

Run the `320`-microstep preflight once and measure both Hall deltas. Only after
direction and slope are confirmed should the driver gain a full opening path.
That path must continuously sample both Hall sensors, stop at the measured
upper endpoint, reject no-progress or inverted motion, retain the OxygenOS
count as a hard ceiling, and leave the motor unpowered afterward. IMX471
streaming and libcamera integration follow only after opening is confirmed.
