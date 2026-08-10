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

## Next step

Implement a minimal modern platform driver for the pop-up mechanism. Movement
must be time- and step-bounded, sample both Hall sensors continuously, stop on
the measured endpoint, and leave the motor unpowered after every operation.
Only after the upper endpoint is confirmed may IMX471 streaming and libcamera
integration be tested.
