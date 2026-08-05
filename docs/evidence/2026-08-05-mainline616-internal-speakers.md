# Mainline 6.16 internal-speaker bring-up

Date: 2026-08-05

Device: OnePlus 7T Pro (`hotdog`), HD1913

Result: revision `r31` direct-boots and produces objectively measured audio
from the lower internal speaker. Revision `r32` adds the upper amplifier to the
same ASoC backend and passes the strict package and DTB contract; the upper
speaker result remains pending hardware validation.

## Stock-derived contract

OxygenOS `/vendor/etc/mixer_paths_tavil.xml` selects `S24_LE` for
`QUAT_MI2S_RX`. The stock machine driver consequently generates a 3.072 MHz
bit clock for 48 kHz stereo with 32-bit slots. The stock `tfa98xx.cnt` maps the
upper amplifier at I2C address `0x34` to TDM slot 0 and the lower amplifier at
`0x35` to slot 1.

The mainline driver applies the matching register profile while preserving a
strict safety sequence:

1. Output is powered down while the profile is prepared.
2. The CPU DAI supplies BCLK and frame sync.
3. The driver waits at most 20 ms for both TFA clock-lock flags.
4. The amplifier stage is enabled only after lock.
5. Stream close and every error path return to power-down.

The shared physical reset GPIO is not requested or toggled.

## Validated artifacts

| Artifact | Size | SHA256 |
|---|---:|---|
| Kernel APK `6.16.0-r31` | 25,542,845 bytes | `7faf2116f6b0cd74140a62002210f29119cd217f4ed55f39b0a4e8e5c8f5fa5f` |
| Partition-sized r31 AVB image | 100,663,296 bytes | `226dd8bb0bcd21cf4d544d7f9042994a4d0e00f6e9aa93f94e267287124552c3` |
| Kernel APK `6.16.0-r32` | 25,542,848 bytes | `997dfeaa1327a868f2901b5125f6b66542056202cd291118ded9063529295c7d` |

The r31 image passed AVB verification and a full `boot_b` readback before the
hardware run. The r32 strict build reports `hotdog mainline 6.16 build
contract: PASS`; its final DTB contains both speaker phandles in slot order.

## Lower-speaker hardware result

The r31 direct boot reports kernel build
`#32-oneplus-hotdog-mainline616` and boot ID
`04405550-128c-4a37-947b-d178c23eb5cc`. Card 0 is `OnePlus 7T Pro`, and
`MultiMedia1` opens at 48 kHz, stereo, S24_LE.

Before playback, the lower amplifier reports:

```text
slot=1 configured=1 active=0 system=0001 status0=0016 status1=0000 status3=010f
```

During playback it reports stable clocks and an enabled output stage:

```text
slot=1 configured=1 active=1 system=0018 status0=0016 status1=e2c0 status3=850f
```

After playback it returns to `active=0`, `system=0001`, and the
`QUAT_MI2S_RX Audio Mixer MultiMedia1` route is disabled.

## Independent acoustic measurement

A UGREEN webcam microphone recorded each complete test at 48 kHz, stereo,
16-bit PCM. The capture began before ALSA routing, and both the webcam source
and phone mixer were restored to muted/off afterward. The first stimulus was a
one-second, fade-bounded, 1 kHz stereo S24_LE signal at -60 dBFS.

| Capture window | Measured 1 kHz component |
|---|---:|
| Local baseline | approximately -85 to -95 dBFS |
| Stereo stimulus, stable interval | approximately -43 dBFS |
| Left-channel-only stimulus | no component above baseline |
| Right-channel-only stimulus | approximately -43 dBFS |

The channel-isolated test used valid S24_LE zero padding and identical sample
amplitude. It establishes that the lower slot-1 amplifier consumes the right
PCM channel. The microphone result is independent of visual observation and
of the amplifier status registers.

| Evidence file | SHA256 |
|---|---|
| `webcam-mic-s24-minus60dbfs-r31.wav` | `8129d3dfd95005f3767bf00f3ceaff0de90e76f688c00c94d54372db42e37268` |
| `webcam-mic-s24-minus48dbfs-r31.wav` | `1964a101db8fe33729ef22eee84f74ccf48e74abad972f431785023d94a2512f` |
| `webcam-mic-s24-minus48dbfs-left-then-right-r31-v2.wav` | `839e6e9179b5053de830ea88b1bfb7da87b5a3a376f02ff9be0902f14966fa02` |

The WAV files are retained as local laboratory artifacts rather than committed
to the source repository.

## Next gate

Install and direct-boot r32, verify both amplifiers bind to the speaker DAI,
then repeat the same low-level left/right acoustic capture. Only after both
channels pass should the route be exposed through UCM and normal Plasma volume
controls. Headphones, the earpiece, microphones, headset detection, and longer
thermal/protection validation remain separate gates.
