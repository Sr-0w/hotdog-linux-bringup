# Mainline 6.16 ADSP runtime validation

Date: 2026-08-05

Device: OnePlus 7T Pro (`hotdog`), HD1913

Result: the isolated ADSP candidate direct-boots from the OnePlus bootloader,
loads the handset firmware, reaches `running`, and exposes the expected APR
audio services. This result does not yet claim an ALSA sound card or a working
speaker, earpiece, microphone, headset, or Bluetooth-audio route.

## Scope

Revision `r23` changes one hardware contract relative to the accepted `r22`
image: it enables `remoteproc@17300000` and selects
`qcom/sm8150/oneplus/hotdog/adsp.mbn`. SLIMbus, WCD9340, the machine sound card,
and the external TFA98xx amplifiers remain outside this experiment.

The 30 MiB ADSP reservation at `0x8be00000` remains `no-map`. The package
validator also requires the Qualcomm PAS remoteproc module and resolves the DT
memory-region phandle back to that reservation.

## Reproducible artifacts

The strict pmbootstrap build and the package-generated AVB image produced:

| Artifact | Size | SHA256 |
|---|---:|---|
| Kernel APK `6.16.0-r23` | 25,537,641 bytes | `5b6ca6301b716b19c4ff6fb8f95e7104d2b3fdfed903d9a4c78a77b4200ad96a` |
| Kernel `Image` | 27,572,232 bytes | `9b1ce091d7bd77ce907e1cb6759da6b7916b07af92b67f9cf91215384dde3d76` |
| Hotdog DTB | 141,070 bytes | `2af0807b12f703e8ee2137d71c19e259792fc91cbb1ba7687adbeb4937b89c0d` |
| `qcom_q6v5_pas.ko` | 61,200 bytes | `2a41167803a37fe813decdd3b74ecfe220d5956be09941992ab137f07c764a50` |
| Partition-sized AVB `boot.img` | 100,663,296 bytes | `836ec4b04de9d5a584b9db88b168ec81dc0c288baa410781442c411b2c406819` |

The AVB descriptor verifies the original 37,203,968-byte image. Unpacking the
final image reproduces the exact kernel and DTB hashes above. Before writing
the candidate, the accepted `r22` `boot_b` image was read back completely and
preserved with SHA256
`9b58a17e90d783c2780af65e35bc5ae706811bdf830a1c49b6cef475e77b6f79`.
The candidate write and full 96 MiB partition readback both matched the r23
hash.

## Hardware result

The fresh direct boot reports:

| Item | Observed value |
|---|---|
| Kernel build | `#24-oneplus-hotdog-mainline616` |
| Boot ID | `eb6dbc9c-93e2-4226-bcd7-8d6156a2b6ee` |
| ADSP firmware | `qcom/sm8150/oneplus/hotdog/adsp.mbn`, 14,459,152 bytes |
| ADSP state | `running` |
| MPSS state | `running` |
| USB recovery channel | NCM and SSH returned automatically |

The kernel reports that the ADSP firmware booted successfully and registers
APR services 3, 4, 7, and 8. The Q6ASM DAI child then fails with
`No dais found in DT`, which is the expected boundary for this isolated stage:
the DSP and APR transport are alive, but no machine topology describes usable
front-end and back-end DAIs. `/proc/asound/cards` therefore remains empty.

## Next gate

The next candidate may enable only the existing SM8150 SLIMbus/WCD9340
transport with the stock-derived GPIO 123 interrupt, GPIO 143 reset, 9.6 MHz
clock, and 1.8 V supplies. It must keep the sound card and unsupported external
speaker amplifiers absent until the codec transport binds cleanly.
