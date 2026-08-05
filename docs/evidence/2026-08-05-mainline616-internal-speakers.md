# Mainline 6.16 internal-speaker bring-up

Date: 2026-08-05

Device: OnePlus 7T Pro (`hotdog`), HD1913

Result: revision `r32` direct-boots and produces independently measured audio
from both internal speakers. Slot-isolated S24_LE stimuli map the upper slot-0
amplifier to the left PCM channel and the lower slot-1 amplifier to the right
PCM channel. Both amplifiers return to power-down after every stream.

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
| Partition-sized r32 AVB image | 100,663,296 bytes | `d2be86069bdda8e4293d43e17d07ce56b483f5561aa0ee1f8959e53fda39c0b9` |

Both images passed AVB verification and a full `boot_b` readback before their
hardware runs. The r32 strict build reports `hotdog mainline 6.16 build
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

## Stereo hardware result

The r32 direct boot reports kernel build `#33-oneplus-hotdog-mainline616` and
boot ID `233dcadb-088f-4a62-8817-8eecfc42eb25`. Both TFA9874 devices bind to
the same speaker DAI: `1-0034` uses slot 0 and `1-0035` uses slot 1.

During either isolated stream, both codecs report locked clocks and an active
output stage:

```text
slot=0 configured=1 active=1 system=0018 status0=0016 status1=e2c0 status3=850f
slot=1 configured=1 active=1 system=0018 status0=0016 status1=e2c0 status3=850f
```

Fresh, separate ten-second webcam-microphone captures were made for each
channel. Each capture contains a one-second 1 kHz S24_LE stimulus at -48 dBFS.

| Stimulus | Local baseline | Stable 1 kHz component | Physical result |
|---|---:|---:|---|
| Left PCM channel | approximately -82 dBFS | approximately -58.9 dBFS | Upper slot-0 speaker emits audio |
| Right PCM channel | approximately -88.5 dBFS | approximately -43.0 dBFS | Lower slot-1 speaker emits audio |

The difference in captured level reflects the physical speaker and webcam
geometry; it is not used as a gain calibration. After each capture, the PCM is
closed, the mixer route is off, and both codecs report `active=0`,
`system=0001`, and `status1=0000`.

| Evidence file | SHA256 |
|---|---|
| `webcam-mic-s24-minus48dbfs-left-r32.wav` | `b1637a35b84b55abb819c529fca398e77dc98090880e69908512803ec449a5cf` |
| `webcam-mic-s24-minus48dbfs-right-r32.wav` | `9aeb2736bdd2b2a5c981574fa975f5ea98dfd1fcf99b9ad92e525c60b3500d05` |

## Plasma and PulseAudio integration

Device package `device-oneplus-hotdog-3-r8.apk` adds a minimal UCM2 profile
containing only the validated speaker route. The 3,548-byte APK has SHA256
`9247f67021f8da13ba7355bc0b848fbe9cb2ae7f4e9b201cfd9bb3f2480a39e5`.
It installs:

- the SM8150 card mapping for ALSA long name `OnePlus 7T Pro`;
- a `HiFi` verb with one `Speaker` device on `hw:${CardId},0`;
- one enable and one disable operation for
  `QUAT_MI2S_RX Audio Mixer MultiMedia1`.

No gain, microphone, headphone, WCD9340, reset, or protection control is
changed. `alsaucm` discovers the `HiFi` verb and `Speaker` device. After a
PulseAudio reload from the installed package, Plasma exposes the sink as
`Built-in Audio Internal speakers`.

A regular `paplay` invocation sent a one-second stereo 1 kHz WAV at -48 dBFS
through that sink. Both codecs reported clock lock and `active=1`; the
synchronized webcam recording measured an approximately -46.8 dBFS 1 kHz
component against an approximately -73 dBFS median baseline. PulseAudio then
suspended the sink, closed the PCM, and returned both codecs to `active=0`.

Changing the Plasma/PulseAudio sink volume from 100% to 25% changed no ALSA
mixer control, confirming software attenuation rather than an unvalidated
hardware-gain write.

| Evidence file | SHA256 |
|---|---|
| `webcam-mic-pulseaudio-speaker-minus48dbfs-r32.wav` | `09b0100f9e9f28480ee0bb0c5c00d786d88d0bdd4013a0734367bafa606b385d` |

## Next gate

Validate the same packaged route after a full image installation and reboot,
then establish conservative default volume and longer thermal/protection
coverage. Headphones, the earpiece, microphones, and headset detection remain
separate hardware gates.
