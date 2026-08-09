# Mainline 6.16 telephoto camera capture

Date: 2026-08-09
Device: OnePlus 7T Pro HD1913, slot B
Kernel: `6.16.0-sm8150 #84-oneplus-hotdog-mainline616`
Package revision: `linux-oneplus-hotdog-mainline616-6.16.0-r83`

## Result

Revision `r83` adds the missing `GCC_CAMERA_HF_AXI_CLK` consumer to both SM8150
VFE resources. This resolves the CAMNOC `Disconnected target` fault and makes
the complete physical telephoto path functional:

```
S5K3M5 -> CSIPHY0 -> CSID0 RDI0 -> VFE0 RDI0 -> CAMNOC -> Apps SMMU -> RAM
```

The test began from clean Linux boot ID
`8cebfdc6-2f98-4e1e-81e4-dd2ef33427a3`. The CSID test generator was never
enabled during this boot before the physical capture.

## Capture

The media graph dynamically identified `s5k3m5 6-0010` at
`/dev/v4l-subdev14`. Every subdevice was configured for
`SGRBG10_1X10/4208x3120`; `/dev/video0` reported packed `pgAA`, a 5,264-byte
stride and a 16,423,680-byte image size.

Two userspace buffers were prefilled with `0xAA`, then three frames were
captured:

| Sequence | Bytes different from prefill | SHA256 |
| --- | ---: | --- |
| 0 | 16,416,627 | `f12730eada640c71aee1bad399cc854eff65a1b9a5ad2095f926937d0643f69b` |
| 1 | 16,416,536 | `fdffe0be7ce8348cadc06a6e4a322ec7dcc08b3f0713536152eb37127f72edf6` |
| 2 | 16,416,756 | `af6202a313cb559aa6ce41b243bbb03192d832b0a1ce5ca3910ff5ce809b60ec` |

The complete buffers changed, their hashes differ, and the timestamps show the
expected roughly 30 fps cadence. The first frame decodes as MIPI RAW10 GRBG and
contains a real optical scene. The narrow 61-to-72 sample range reflects the
sensor's fixed initial exposure and gain; automatic controls are not yet
implemented.

## Fault checks

The VFE log reports the expected 5,264-byte stride and alternating buffer IOVAs.
There is no SMMU or IOMMU fault. A read-only post-capture register check found
CAMNOC `ERRVLD` and every error-log word equal to zero.

The exact r83 package SHA256 is
`90c63bad049c5b7736202e156a9298031148b09680d8b7c3770a8216a571ae16`.
The direct-boot image SHA256 is
`aa8b1441f2deb7b42fadc4dd739b711ddaf87a6b593e4a9136c0b7e57041f6f8`.

## Reproduction

Use `scripts/test-mainline616-camera-csid-tpg.sh --source s5k3m5` on a clean
r83 boot. The script discovers the sensor entity by name rather than assuming
an unstable CCI bus number. Convert the captured frame with:

```sh
scripts/raw10-to-png.py first-frame.raw first-frame.png \
  --width 4208 --height 3120 --stride 5264 --pattern GRBG
```

The decoder handles line padding, unpacks all ten bits, applies a small
bilinear Bayer preview and prints the measured level statistics.
