# S5K3M5 libcamera and Plasma Camera validation

This report records the first complete userspace validation of the OnePlus 7T
Pro telephoto camera on the mainline 6.16 bring-up kernel. The test ran on a
physical European HD1913 handset, directly booted from the stock bootloader.

## Tested build

- Kernel package: `linux-oneplus-hotdog-mainline616-6.16.0-r90`
- Running identity: `6.16.0-sm8150 #91-oneplus-hotdog-mainline616`
- Boot ID: `6aa5c3b3-dbd0-4bca-8835-5079cab1b021`
- Kernel APK SHA-256: `a9a484221096264b2b701dfb2f3d9c9c8d72a038787701dcf82bf31bb0097c32`
- Boot image SHA-256: `51dfcf2a4107417968f423e8161e2bdea3160294b1758a09265005672b261de6`
- libcamera: `0.7.2`, locally packaged as revision `r2`

The r90 kernel reports native size, crop bounds, default crop and active crop
as `(0, 0)/4208x3120`. Libcamera consequently exposes a 4208x3120 pixel array,
90-degree rotation, rear location and 1000x1000 nm unit cells without the
legacy sensor-driver warning.

## Automatic controls

`deploy-test-mainline616-libcamera.sh` captured 60 processed 640x480 frames
through the simple pipeline and software ISP. Exposure metadata contained 16
distinct values, ranging from 2574 to 6075 us. The IPA advertised exposure
lines 8-1620 and analogue gain 1-16. Gain remained at the 1.0 floor in the
tested illuminated scene, while exposure and colour gains changed live.

The S5K3M5 tuning file loaded from
`/usr/share/libcamera/ipa/simple/s5k3m5.yaml`. The run produced no missing
static-property, sensor-helper or tuning-file warning.

## Application integration

Plasma Camera selected the S5K3M5 through libcamera, acquired the expected
properties, configured a `4200x3120-ABGR8888/sRGB` viewfinder and reached:

```text
PlasmaCameraManager::setReadyForCapture true
```

The software ISP used the Adreno 640 through Mesa for the processed preview.
This validates sensor-to-application integration; automatic focus and final
image-quality calibration remain separate work.

## Reproduction

With the tested kernel and local packages installed on a booted handset:

```sh
export HOTDOG_PMBOOTSTRAP_WORK="$PWD/pmbootstrap-work-r9"
./scripts/deploy-test-mainline616-libcamera.sh
```

The script stages packages in the user's RAM-backed runtime directory, refuses
to run in Qualcomm 900e mode, preserves the boot identity, captures kernel logs
and never flashes or reboots the handset.
