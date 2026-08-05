# Mainline 6.16 TFA9874 passive-probe validation

Date: 2026-08-05

Device: OnePlus 7T Pro (`hotdog`), HD1913

Result: revision `r28` direct-boots from the OnePlus bootloader and binds both
internal NXP TFA9874 amplifiers with a deliberately read-only driver. Both
devices report the production silicon revision `0x0c74`. The driver exposes no
DAI, performs no register write, does not request either reset GPIO, and leaves
both output stages disabled.

## Safety boundary

The production OxygenOS device tree places the upper amplifier at I2C address
`0x34` and the lower amplifier at `0x35`. The lower reset uses GPIO 100, which
is also the active-low enable for the FSA4480 USB-C analogue switch. Revision
`r28` therefore preserves the bootloader pin state and reads only register
`0x03`, the 16-bit silicon revision register.

The build contract rejects register writes, update-bits operations, GPIO or
reset APIs, DAPM widgets, and DAI registration in this stage. It also checks
that both final-DTB nodes omit `reset-gpios` and pinctrl properties. Audible
speaker testing remains prohibited until the stock-derived ADSP protection
profile, calibration data, MI2S4 transport, and shared-reset sequencing are
implemented together.

## Validated artifacts

| Artifact | Size | SHA256 |
|---|---:|---|
| Kernel APK `6.16.0-r28` | 25,540,678 bytes | `5ddca0b5074f9cfdcacedf4c971f6726668caf83d679bef86f510d98c348b761` |
| Kernel `Image` | 27,572,232 bytes | `c73b2db992a68ae191d324583da482ed4a50264aebcf4f922ce022e4c2c9a291` |
| Hotdog DTB | 144,212 bytes | `71f1a41949bbd1b1b1fa7bd6757d5cdd526a5a4e62f3cf610bbd356f79244861` |
| Reused postmarketOS initramfs | 9,478,720 bytes | `e550ecda62e0f1afe62f0fa204d385b05b6d767fb3da6c2c9fd12e68e3052fea` |
| Raw Android boot image | 37,208,064 bytes | `80627d8f2b7292d3f81ec28f1c205943687fc25b4188629a617ccb436361ee0c` |
| Partition-sized AVB `boot.img` | 100,663,296 bytes | `e91c613218826b80ede83ad94ce8100f234792731827f0f1cf28ed4bb2dea615` |

The strict pmbootstrap build passed the complete kernel, source, configuration,
and DTB contract. The image builder unpacked the final Android boot image and
reproduced the exact kernel, DTB, and initramfs hashes. The full 96 MiB write to
`boot_b` was read back with the same AVB-image hash before reboot.

## Hardware result

The fresh direct boot reports:

| Item | Observed value |
|---|---|
| Kernel build | `#29-oneplus-hotdog-mainline616` |
| Boot ID | `3f52dad8-9dbc-48eb-955f-a263d15dbf23` |
| Upper amplifier | `1-0034`, driver `tfa9874`, revision `0x0c74` |
| Lower amplifier | `1-0035`, driver `tfa9874`, revision `0x0c74` |
| USB-C analogue switch | `1-0042`, driver `fsa4480` |
| GPIO 37 | input-low, pull-down, unchanged |
| GPIO 100 | output-low, no pull, unchanged |
| ALSA | card 0 `OnePlus 7T Pro`, `MultiMedia1` playback and capture |
| Recovery channel | USB NCM and SSH returned automatically |

The two exact probe messages are:

```text
tfa9874 1-0034: TFA9874 revision 0x0c74 detected; amplifier remains disabled
tfa9874 1-0035: TFA9874 revision 0x0c74 detected; amplifier remains disabled
```

Wi-Fi, the render node, the FSA4480, and the existing ALSA card remained
available after the change. No TFA9874 probe, I2C, ASoC, ADSP, or FSA4480 error
was logged.

## Next gate

Package the exact OxygenOS `tfa98xx.cnt` and speaker-calibration assets through
the non-free firmware package without committing proprietary payloads. Then
implement the stock MI2S4 and Qualcomm ADSP protection transport while keeping
the output stages disabled. Only after the profile loads and telemetry is sane
may a bounded low-level speaker test be considered.
