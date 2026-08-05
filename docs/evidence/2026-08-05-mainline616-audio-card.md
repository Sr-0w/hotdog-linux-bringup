# Mainline 6.16 ALSA machine-card validation

Date: 2026-08-05

Device: OnePlus 7T Pro (`hotdog`), HD1913

Result: revision `r25` direct-boots from the OnePlus bootloader and registers a
complete ALSA card over the previously validated ADSP, Qualcomm NGD SLIMbus,
WCD9340, and SoundWire transports. Playback and capture PCM devices are
present. No physical speaker, earpiece, microphone, or headset route is claimed
at this stage.

## Scope

The candidate adds the smallest SM8150 machine topology needed to validate the
internal codec path:

- one Q6ASM `MultiMedia1` playback/capture front end;
- `SLIMBUS_0_RX` connected to WCD9340 `AIF1_PB`;
- `SLIMBUS_0_TX` connected to WCD9340 `AIF1_CAP`;
- no external TFA98xx amplifier or speaker link.

The kernel package contract checks all new Q6 modules, configuration symbols,
DT phandles, DAI identifiers, and the deliberate absence of an external
amplifier. The sound-card binding and final DTB also pass the complete Linux DT
schema set.

## Reproducible artifacts

The strict pmbootstrap build and package-generated AVB image produced:

| Artifact | Size | SHA256 |
|---|---:|---|
| Kernel APK `6.16.0-r25` | 25,539,531 bytes | `e7e1ad4f5135b5bcb8fab193f1046ef216f1f2cd7361123a277d0130cada1d51` |
| Kernel `Image` | 27,572,232 bytes | `5d4e28559777c02f11aae667e5d988fc3fe644267cf4bf13591b3bbf461e1907` |
| Hotdog DTB | 143,443 bytes | `cd1e4d8fe4dfb3b97ac8e774416fe90e1e649920e6637d20526ca7cbb352847c` |
| Partition-sized AVB `boot.img` | 100,663,296 bytes | `fb09cebecda9b0d2217dea8c3aa3d9a4a7bab343f0a62fe4c9904f7d38bc0a9b` |

`avbtool` verifies both the footer and the SHA256 descriptor for the original
37,208,064-byte image. Unpacking the final image reproduces the exact kernel
and DTB hashes above. A complete 96 MiB `boot_b` readback matched the image hash
before reboot.

## Hardware result

The fresh direct boot reports:

| Item | Observed value |
|---|---|
| Kernel build | `#26-oneplus-hotdog-mainline616` |
| Boot ID | `fb7f4906-1d08-4ea0-adc2-8551b7269009` |
| ALSA card | card 0, `OnePlus 7T Pro` |
| Playback PCM | card 0, device 0, `MultiMedia1` |
| Capture PCM | card 0, device 0, `MultiMedia1` |
| Machine driver | `snd-sm8150`, bound to `/sound` |
| Codec device | `217:250:1:0`, driver `wcd934x-slim` |
| ADSP state | `running` |
| MPSS state | `running` |
| USB recovery channel | NCM and SSH returned automatically |

`snd-soc-sm8150`, Q6AFE, Q6ASM, Q6 routing, WCD9340, SLIMbus, and SoundWire
modules are loaded. `/dev/snd` exposes playback, capture, control, and timer
devices, while `aplay -l` and `arecord -l` both enumerate `MultiMedia1`.

The first unconfigured PCM request logs `no backend DAIs enabled`. That is the
expected next boundary: the kernel card exists, but userspace has not selected
the `SLIMBUS_0_RX` mixer route and no UCM profile describes safe physical
endpoints yet. The existing isolated SLIMbus `QMI wait timeout` remains visible,
as does the missing headset-button threshold warning. Neither DSP leaves the
`running` state.

## Next gate

Derive the internal routing and headset thresholds from the stock/Lineage
configuration, then add a minimal UCM profile. Validate PCM setup and the
internal earpiece or a controlled codec endpoint before enabling either
external TFA98xx speaker amplifier. Speaker support remains a separate gate
because it also requires the correct amplifier model, bus description,
firmware/calibration requirements, and safe gain limits.
