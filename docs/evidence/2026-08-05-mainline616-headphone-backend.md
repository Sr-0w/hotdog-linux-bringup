# Mainline 6.16 Hotdog headphone backend validation

Date: 2026-08-05

Device: OnePlus 7T Pro (`hotdog`), HD1913

Result: revision `r26` direct-boots from the OnePlus bootloader and validates
the digital playback path from Q6ASM `MultiMedia1` to the WCD9340 headphone
interface through `SLIMBUS_6_RX` and `AIF4_PB`. The test does not enable an
analog output stage and does not claim audible headphone, earpiece, speaker,
or microphone support.

## Route selection

The preceding `r25` topology used `SLIMBUS_0_RX` and reached ADSP status
`0x9` when playback was started. In the Qualcomm ADSP API this status is
`ADSP_EALREADY`, which means that port is already active rather than missing.
The stock Hotdog audio policy instead maps wired-headphone playback to
`SLIMBUS_6_RX`, with the codec receiving that stream on `AIF4_PB` through
`SLIM RX2` and `SLIM RX3`.

Revision `r26` changes only the playback backend:

- Q6AFE DAI: `SLIMBUS_6_RX`;
- WCD9340 DAI: `AIF4_PB`;
- fixed backend parameters: 48 kHz, stereo, S24_LE;
- capture remains on `SLIMBUS_0_TX` and `AIF1_CAP`;
- external TFA98xx speaker amplifiers remain absent.

The build validator checks the final DTB phandles and DAI identifiers so a
future package cannot silently return to the conflicting playback port.

## Reproducible artifacts

| Artifact | Size | SHA256 |
|---|---:|---|
| Kernel APK `6.16.0-r26` | 25,539,545 bytes | `87f5a97fcad44b89b9e0bd6a0ff4a80f2101c85f4452c930472c38b4e0ccfa89` |
| Kernel `Image` | 27,572,232 bytes | `0f96582804d8328bff74022f4c25632b63db2f01844650cf72ab02e88be25076` |
| Hotdog DTB | 143,443 bytes | `3b2cb24d22cf4eb8e79845eecfeca4d619a93c749b3350ff0857390277a521cd` |
| Reused postmarketOS initramfs | 9,478,720 bytes | `e550ecda62e0f1afe62f0fa204d385b05b6d767fb3da6c2c9fd12e68e3052fea` |
| Raw Android boot image | 37,208,064 bytes | `7bc8fd99b401f0af84a0d55bf718ca5ca2bdb93c0fb4539ba5233b1a39dca805` |
| Partition-sized AVB `boot.img` | 100,663,296 bytes | `077a88988427eab0df14d486f10084b99d8ed0dfdfea7bffcee6cfd9a2836fdf` |

The strict pmbootstrap build passed the complete kernel and DTB contract.
`avbtool` verified the final image, unpacking reproduced the exact kernel,
DTB, and initramfs hashes, and a complete readback from `boot_b` matched the
partition-sized image before reboot.

## Hardware result

The fresh direct boot reports:

| Item | Observed value |
|---|---|
| Kernel build | `#27-oneplus-hotdog-mainline616` |
| Boot ID | `e8cef382-06db-4e8a-9c15-61b131bd6f76` |
| ALSA card | card 0, `OnePlus 7T Pro` |
| PCM | card 0, device 0, `MultiMedia1` playback and capture |
| Playback mixer | `SLIMBUS_6_RX Audio Mixer MultiMedia1` |
| Codec muxes | `SLIM RX2 MUX` and `SLIM RX3 MUX`, both accepting `AIF4_PB` |
| ADSP state | `running` before and after playback |
| MPSS state | `running` before and after playback |
| USB recovery channel | NCM and SSH returned automatically |

With no process holding `/dev/snd`, the two codec muxes were temporarily set
to `AIF4_PB`, the `SLIMBUS_6_RX` mixer was enabled, and a silent three-second
raw stream was opened as 48 kHz stereo S24_LE on `hw:0,0`. ALSA accepted the
stream. No Q6ASM, Q6AFE, APR, SLIMbus, audio, DSP, or remoteproc error was
logged. The only new kernel line was the expected SLIMbus satellite master
capability notification. Both remote processors remained running.

The test cleanup disabled the backend, returned both muxes to `ZERO`, and left
the playback and capture PCM states closed. The installed `r25` module tree is
ABI-compatible because `r26` changes only the source-built DTB; the complete
`r26` package still needs to replace it in the persistent root filesystem.

## Next gate

Package a minimal UCM2 profile for the WCD9340 wired-headphone path and derive
the safe analog codec controls from the stock mixer configuration. First
validate silence and low-level headphone output with the external speaker
amplifiers absent. Earpiece, microphones, headset detection/button thresholds,
and TFA98xx speakers remain independent hardware gates.
