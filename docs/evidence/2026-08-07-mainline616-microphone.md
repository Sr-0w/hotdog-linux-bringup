# Internal microphone - 2026-08-07

## Result

The handset microphone works. It is exposed to Plasma and PulseAudio as
`alsa_input.platform-sound.HiFi__Mic__source`, captures real acoustic content
with correct frequency discrimination, and works from the packaged profile
alone with no manual mixer commands.

## Starting point

Revision `r32` exposed a single PCM, `MultiMedia1`, with a capture front end
and no reachable back end. The `slimcap-dai-link` back end (`SLIMBUS_0_TX` to
`AIF1_CAP`) already existed and the codec node already carried
`qcom,micbias1-microvolt` through `micbias4`, but `audio-routing` contained
only `"RX_BIAS", "MCLK"`, so no analogue microphone input reached a bias supply
and every ADC path stayed powered down.

## Changes

| Revision | Change |
| --- | --- |
| `r36` | `0043`: route AMIC1-AMIC5 to the bias supplies read from the stock overlay. |
| `r34` | `0044`: add `MultiMedia2` as a second Q6ASM front end with its own DAI link. |
| `r35` | `0045`: map the ports of every SLIMbus link, not only the first. |
| device `3-r13` | UCM `Mic` device on PCM 1, AMIC4 control order, capture gains with headroom. |

Three separate defects had to be fixed before any sound arrived. Each is
recorded below because each produced a different, misleading symptom.

### A shared front end breaks the whole card

Playback and capture cannot share `MultiMedia1`. A capture stream is only
openable once its front end is joined to `SLIMBUS_0_TX`, and PulseAudio probes
the PCM before it applies any use-case sequence. With one shared PCM the probe
fails and `module-alsa-card` rejects the **whole** card, so adding a microphone
made the speakers disappear as well.

`0044` gives capture its own `MultiMedia2` front end: playback stays on PCM 0,
capture moves to PCM 1. This follows the Realme X3 profile in pmaports, which
is also SM8150 with a WCD934x codec.

### Only the first SLIMbus link was given a channel map

`sm8150_dai_init()` runs once per DAI link, but `for_each_rtd_codec_dais()`
only walks the codec DAIs of the link being initialised, while the
`slim_port_setup` flag is stored per card. The first SLIMbus back end consumed
the flag, so `AIF1_CAP` never received a channel map,
`wcd934x_get_channel_map()` reported zero TX channels, and no SLIMbus TX port
was opened. Capture returned a perfectly running stream of exact digital
silence.

This is invisible on a board with a single SLIMbus back end. Hotdog has two,
because headphone playback uses `SLIMBUS_6_RX`. `0045` maps the ports of every
SLIMbus link and leaves the flag guarding only the jack registration, which
really is a per-component operation.

### The handset microphone is AMIC4, and it needs MIC BIAS1

With transport fixed, capture carried live data but no acoustic content, and a
runtime sweep of `AMIC MUX0` across ADC1 to ADC4 was silent on all four. The
bias assignment was wrong: `0043` originally paired AMIC4 with MIC BIAS4.

The stock OxygenOS `dtbo` (`androidboot.dtbo_idx=5`) supplies the real wiring.
The handset sound card is `fragment@95`, identified by
`oplus,speaker-pa = "nxp"`, `oplus,usbc-switch`, `qcom,wsa-max-devs = <0>`, and
the `tfa98xx_right@34` amplifier node immediately after it. Its
`qcom,audio-routing` gives each input a supply and a name:

| Pad | Supply | Stock label |
| --- | --- | --- |
| AMIC1 | MIC BIAS1 | - |
| AMIC2 | MIC BIAS2 | Headset Mic |
| AMIC3 | MIC BIAS4 | ANCRight Headset Mic |
| AMIC4 | MIC BIAS1 | ANCLeft Headset Mic |
| AMIC5 | MIC BIAS1 | Handset Mic |

Correcting AMIC4 to MIC BIAS1 is what made capture work. The stock *labels*,
however, do not describe this handset. Selecting AMIC5, which the overlay calls
the handset microphone, captures nothing. A pad sweep with all five routes in
place, measured against room sound, is unambiguous:

| Pad | RMS | level variation over time |
| --- | --- | --- |
| AMIC1 | `-18.9` dBFS | `5.32` dB |
| AMIC2 | `-45.1` dBFS | `0.37` dB |
| AMIC3 | `-16.9` dBFS | `5.56` dB |
| **AMIC4** | `-18.4` dBFS | `4.85` dB |
| AMIC5 | `-41.2` dBFS | `0.28` dB |

AMIC1, AMIC3 and AMIC4 carry real sound; AMIC2 and AMIC5 carry only front-end
noise. The odm mixer configuration, which resolves `handset-mic` to `amic4`,
matches the hardware, so the profile uses AMIC4. AMIC1 and AMIC3 are the other
two physical microphones and remain unused for now.

DAPM state during capture confirms the corrected wiring powers the analogue
front end:

```
MIC BIAS1     On
AMIC4_5 SEL   On   in 1 out 1
ADC4          On   in 1 out 1
MIC BIAS2     Off
```

## How this was validated, and how it was nearly mis-validated

Two measurements initially looked like proof and were not. They are recorded
because both are easy to repeat and both are misleading.

**Playing a tone on the handset's own speakers proves nothing.** A three-tone
test showed each tone strongest in its own analysis bin by 16 to 46 dB, which
looks conclusive. It was run while AMIC5 was selected, and AMIC5 is a silent
pad, so the frequency structure can only have come from internal coupling
between the playback and capture sides of the codec. An acoustic check needs a
source that is not the device under test.

**Level tracking the analogue gain proves only that the ADC amplifies.** With
AMIC5 selected, ambient RMS moved `-87.9`, `-80.6`, `-65.5` dBFS across
`ADC4 Volume` 0, 8 and 20, matching the control's step size. That is real
analogue behaviour, but the thing being amplified was the front end's own
noise, not a microphone.

The listening check is what caught it: the capture sounded like television
static. A spectral-structure measurement agrees. Front-end noise is close to
flat and steady, while room sound fluctuates, so the standard deviation of the
short-term level separates them cleanly.

### Pad sweep against room sound

With all five bias routes in place and identical gains, each pad was recorded
while a video played in the room:

| Pad | RMS | level variation over time |
| --- | --- | --- |
| AMIC1 | `-18.9` dBFS | `5.32` dB |
| AMIC2 | `-45.1` dBFS | `0.37` dB |
| AMIC3 | `-16.9` dBFS | `5.56` dB |
| **AMIC4** | `-18.4` dBFS | `4.85` dB |
| AMIC5 | `-41.2` dBFS | `0.28` dB |

For reference, synthetic white noise measures `0.05` dB of variation and pink
noise `0.77` dB. AMIC1, AMIC3 and AMIC4 are 25 dB louder and an order of
magnitude more variable than AMIC2 and AMIC5. The AMIC3 and AMIC4 recordings
were confirmed by ear to contain the actual room audio.

### Capture gain

At `ADC4 Volume` 20 the digital decimator gain sets the working level.
`DEC0 Volume` 108 clipped, so the profile uses 96:

| `DEC0 Volume` | RMS | peak |
| --- | --- | --- |
| 84 | `-56.7` dBFS | `-26.5` dBFS |
| 90 | `-52.3` dBFS | `-18.9` dBFS |
| **96** | `-42.3` dBFS | `-14.4` dBFS |
| 108 | `-18.4` dBFS | `0.0` dBFS, clipped |

Recordings at 90 and 96 were confirmed by ear to contain keyboard typing in
the room, which is an acoustic source unrelated to anything the device plays.

### Packaged profile

After installing `device-oneplus-hotdog 3-r13` and reloading the audio service,
a capture through the packaged profile alone, with no manual mixer commands,
measured `-37.1` dBFS RMS with `5.28` dB of level variation. The controls read
back as AMIC4 on the shared mux, ADC4 into the AMIC mux, `ADC4 Volume` 20 and
`DEC0 Volume` 96, confirming the profile established the route rather than a
leftover manual setting.

A quiet moment in the room measures around `0.3` dB of variation on the same
path, so a single silent capture is not evidence of failure; the comparison
has to be made against a known acoustic source.

## Playback regression check

`0045` touches the shared SLIMbus init path, so playback was re-verified:
`paplay` through PulseAudio succeeded and both TFA9874 amplifiers reported
`active=1`, returning to `active=0` on sink suspend. No regression.

## Still open

- Only the handset microphone on AMIC4 is enabled. AMIC1 and AMIC3 also carry
  real sound and have no UCM device; which physical microphone each one is has
  not been established. AMIC2 and AMIC5 are silent on this handset even though
  the stock overlay labels AMIC5 as the handset microphone, so the stock labels
  should not be trusted without a measurement.
- The six digital microphones have no bias routes in the device tree and were
  never tested.
- The capture gains are fixed in the profile rather than exposed as a usable
  volume control.
- Echo cancellation and any noise suppression are absent, so simultaneous
  playback and capture will feed the speakers back into the microphone.
- The analyzer's `--min-margin` is an absolute threshold and will report a
  false pass on noise. Capture checks must compare against a recorded control,
  as the tables above do.
