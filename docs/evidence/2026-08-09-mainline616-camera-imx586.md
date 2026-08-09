# Sony IMX586 main-camera validation

Revision `r99` replaces the diagnostic CCI scanner with a V4L2 sensor driver
for the OnePlus 7T Pro main Sony IMX586. The driver uses the exact OxygenOS
power sequence and 4000x3000 binned RAW10 register tables, then sends three
C-PHY trios through SM8150 CSIPHY1, CSID0, VFE0 RDI0 and system memory.

## Kernel and raw capture

The tested direct-boot image has SHA-256
`87b51a3af95ce1a72e2ebff9d09b06fe8095be02c48004fe82b1729e24e0e6fb`.
The installed kernel reports `6.16.0-sm8150 #100-oneplus-hotdog-mainline616`.
Libcamera enumerates `imx586 5-001a` as camera 1 with
`SRGGB10_1X10/4000x3000` on `/dev/v4l-subdev14`.

Three raw frames completed at 30.02 fps. Each frame is 15,024,000 bytes,
matching a 5008-byte CAMSS stride times 3000 lines, and all three SHA-256
digests differ. The converted image is coherent and free of transport,
CAMNOC and SMMU corruption. Focus is not yet integrated for the main module.

## Libcamera automatic controls

Libcamera package revision `r3` adds:

- the Sony gain law `gain = 1024 / (1024 - register)`;
- a measured 64-code RAW10 black pedestal;
- OxygenOS delay data: two frames for exposure, gain and frame length;
- the 0.8 micrometre pixel pitch;
- a simple-pipeline IPA profile with black-level, AWB, adjust and AGC.

The package hashes are:

| Package | SHA-256 |
|---|---|
| `libcamera-99990.7.2-r3.apk` | `93c126e1c339b67783abec67025c92f4b200ef83a58fb506811b40fdd91b4b77` |
| `libcamera-ipa-99990.7.2-r3.apk` | `ded5d95c74dfe7481ad7af733119f366ecb2875c290f9b1ffacb3f112dbd6d2e` |
| `libcamera-tools-99990.7.2-r3.apk` | `57ae90c4c1932ef2e124484d724edc41650974b5b2db5208ee1db27504a8e74c` |

A 60-frame 640x480 ABGR8888 viewfinder run completed at 30 fps through the
software ISP and Adreno 640 EGL path. In the tested dark scene, exposure held
at 25,207 microseconds while automatic analogue gain traversed 16 distinct
values from 1.122807x to 5.657459x. This proves that statistics reach the IPA
and that its output controls the physical sensor.

## Plasma Camera and device arbitration

Plasma Camera opened the IMX586 stream and reported
`PlasmaCameraManager::setReadyForCapture true`. WirePlumber's passive
libcamera monitor originally kept the single CAMSS graph open and prevented
direct libcamera applications from configuring it. The hotdog device package
therefore disables only `monitor.libcamera`; WirePlumber continues to manage
audio, while camera applications access libcamera directly.

## Complete userspace metadata, revision `r100`

Revision `r100` adds the native 8000x6000 pixel-array geometry and reports the
board orientation and 90-degree rotation through standard V4L2 controls. Its
direct-boot image has SHA-256
`715999dc33b5354771b7f6bd55ebdd3b956ff33af7da21146075135052f4b49c`.
The image was read back byte-for-byte from `boot_b` before booting.

The validated boot reports kernel build
`#101-oneplus-hotdog-mainline616` and boot ID
`03ca6bb9-8524-4eff-bd0a-bb94903d49ef`. Libcamera enumerates the IMX586 as an
internal back camera without its previous missing geometry or orientation
warnings. A fresh 60-frame ABGR8888 viewfinder run again completed at 30 fps,
used the Adreno 640 software-ISP path, and moved analogue gain through the same
16 values from 1.122807x to 5.657459x. Plasma Camera again reported
`PlasmaCameraManager::setReadyForCapture true`.

Remaining IMX586 work is main-lens actuator integration, production colour and
AWB calibration, and additional sensor modes. Those limitations do not
invalidate raw capture, automatic exposure and gain, complete userspace
metadata, or Plasma Camera integration.
