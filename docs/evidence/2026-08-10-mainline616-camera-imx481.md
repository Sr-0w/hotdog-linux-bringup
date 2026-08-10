# Sony IMX481 ultra-wide camera validation

Kernel package revision `r111` and libcamera revision `r8` complete the first
hardware-validated mainline path for the OnePlus 7T Pro ultra-wide camera.
The physical sensor is on CCI1 master 1 (`i2c-7`) at address `0x1a`, uses
MCLK3 at 19.2 MHz and sends four-lane D-PHY RAW10 through CSIPHY3. This proves
that the earlier slot-2 inference was wrong: the IMX481 is physical slot 3.

## Kernel and hardware path

The driver uses the recovered OxygenOS power sequence and the full 4656x3496
mode table. The device tree supplies the 1.8 V I/O rail, shared 3.32 V BOB
analogue rail, PM8009 L4 digital rail, PM8150L GPIO2 analogue gate and GPIO23
reset. A clean direct boot of kernel `6.16.0-sm8150
#112-oneplus-hotdog-mainline616` registered `imx481 7-001a` and completed the
media graph through CSIPHY3, CSID0, VFE0, CAMNOC, the SMMU and RAM.

The first probe exposed a precise control-range defect. The mode frame length
is 3550 lines and OxygenOS specifies an 18-line exposure margin, so the maximum
valid exposure is 3532 (`0x0dcc`). The initial default of 3536 made
`v4l2_ctrl_cluster()` reject the controls with `-ERANGE`. Revision `r111`
keeps the default at `0x0dcc`; the sensor then registers without warnings.

## Capture evidence

Two consecutive processed captures completed 180 frames each at approximately
30 fps. Every frame was 1,228,800 bytes at 640x480 XRGB8888. The kernel logged
two independent starts of:

```text
imx481 7-001a: streaming 4656x3496 RAW10 over four-lane D-PHY
```

All 360 requests completed. No CSID reset timeout, CAMNOC fault or SMMU fault
appeared. A retained first processed frame is a coherent wide-angle scene with
SHA-256 `296ff432923311bf85bab840293bf5d3f9308aef4202da00de16877f64de0f3e`.

## Libcamera and Plasma Camera

Libcamera `r8` adds IMX481 sensor properties, the Sony
`gain = 1024 / (1024 - code)` conversion, the 64-code RAW10 black pedestal and
the OxygenOS two-frame exposure, gain and blanking delays. It loads
`/usr/share/libcamera/ipa/simple/imx481.yaml` without missing-property, helper
or tuning warnings. Automatic controls expose a 1-3532-line exposure range and
1x-16x analogue gain range.

Plasma Camera enumerated all three supported rear sensors. With IMX481 selected
explicitly, it acquired model `imx481`, configured a
`4648x3496-ABGR8888/sRGB` viewfinder and reported:

```text
PlasmaCameraManager::setReadyForCapture true
```

The application preference was restored to IMX586 after the test. This
validates the IMX481 from the physical sensor through the normal mobile camera
application. Production colour and lens-shading calibration and additional
sensor modes remain open.

## Reproducible artifacts

| Artifact | SHA-256 |
|---|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r111.apk` | `219816f51cb590f50b925d964b7fd8fd18183404203ec5b4aab364626c857d08` |
| `libcamera-99990.7.2-r8.apk` | `0623a5f26e7512a62f73d4cd7b76cbda8b879f3565cc4aa109778ca6281a7b7f` |
| `libcamera-ipa-99990.7.2-r8.apk` | `8294045778f9e8b64452c2ded68429cb8491206ced096ffa194fe9ee282f2a63` |
| `libcamera-tools-99990.7.2-r8.apk` | `78ff883de2bc122a8d48caada7a848b9c4ef731992e70ab679befdf6cd3301ca` |
| `2026-08-10-r111-imx481-ultrawide-fix/boot.img` | `794e0b948d8ddf721c9cb82dde3c38a59748bc2cc4f5d9f102ce01bbbf114b22` |

