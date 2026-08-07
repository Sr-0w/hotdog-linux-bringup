# Microphone capture path - 2026-08-07

## Result

Partial. The capture path is now plumbed end to end and carries live data, but
the internal microphone is not yet acoustically validated. Do not describe the
microphone as working.

## Starting point

Revision `r32` exposed a single PCM, `MultiMedia1`, with a capture front end
and no reachable back end. The `slimcap-dai-link` back end
(`SLIMBUS_0_TX` to `AIF1_CAP`) already existed and the codec node already
carried `qcom,micbias1-microvolt` through `micbias4`, but `audio-routing`
contained only `"RX_BIAS", "MCLK"`, so no analogue microphone input reached a
bias supply and every ADC path stayed powered down.

## Changes

| Revision | Change |
| --- | --- |
| `r33` | `0043`: route AMIC1-AMIC4 to MIC BIAS1-MIC BIAS4 in `audio-routing`. |
| `r34` | `0044`: add `MultiMedia2` as a second Q6ASM front end with its own DAI link. |
| `r35` | `0045`: map the ports of every SLIMbus link, not only the first. |
| device `3-r10` | UCM gains a `Mic` device on PCM 1 and the OxygenOS `amic4` control order. |

### Why a second front end was required

Playback and capture cannot share `MultiMedia1`. A capture stream on this card
is only openable once its front end is joined to `SLIMBUS_0_TX`, and PulseAudio
probes the PCM before it applies any use-case sequence. With one shared PCM the
probe fails and `module-alsa-card` rejects the **whole** card, so the speakers
disappeared as well. This was reproduced and then fixed: with `r34` plus device
`3-r10`, PulseAudio exposes both
`alsa_output.platform-sound.HiFi__Speaker__sink` and
`alsa_input.platform-sound.HiFi__Mic__source`.

The split follows the Realme X3 profile in pmaports, which is also SM8150 with
a WCD934x codec and puts capture on `MultiMedia2`.

### Why the SLIMbus port mapping was wrong

`sm8150_dai_init()` runs once per DAI link, but `for_each_rtd_codec_dais()`
only walks the codec DAIs of the link being initialised, while the
`slim_port_setup` flag is stored per card. The first SLIMbus back end to be
initialised consumed the flag, so `AIF1_CAP` never received a channel map,
`wcd934x_get_channel_map()` reported zero TX channels, and no SLIMbus TX port
was opened. Capture returned a perfectly running stream of exact digital
silence. This is invisible on a board with a single SLIMbus back end; hotdog
has two, because headphone playback uses `SLIMBUS_6_RX`.

## Hardware measurements

All captures were taken through the normal PulseAudio source with
[`analyze-tone-capture.py`](../../scripts/analyze-tone-capture.py).

| Kernel | Capture state |
| --- | --- |
| `r34` (`#35`) | stream runs 8.10 s, every sample exactly zero, RMS `-inf` dBFS |
| `r35` (`#36`) | stream runs, RMS `-70.2` dBFS, non-zero samples |

So `r35` moved the path from exact digital silence to live data. That is a real
transport result and it is the reason the change is kept.

It is **not** an acoustic result. A 1 kHz reference tone played from a host
speaker was not distinguishable from the codec's own noise:

| Run | RMS | level at 1 kHz | noise floor | margin |
| --- | --- | --- | --- | --- |
| control, no tone | `-70.2` dBFS | `-104.1` dBFS | `-118.9` dBFS | `14.7` dB |
| test, 1 kHz tone | `-70.3` dBFS | `-118.6` dBFS | `-119.2` dBFS | `0.7` dB |

The control scores *higher* than the test, so both figures are noise. The
analyzer's fixed 12 dB margin is too permissive for a signal this weak and
reports a false pass on the control; a capture check must compare against a
recorded control rather than an absolute threshold.

## Leading hypothesis for the remaining gap

The ADC now digitises, but nothing acoustic reaches it, which is what a mic
that is never biased looks like. The bias permutation is the first thing to
re-test. `0043` uses the assignment carried by the ClearStaff hotdog device
tree, pairing each input with the matching supply:

```
"AMIC1", "MIC BIAS1", "AMIC2", "MIC BIAS2",
"AMIC3", "MIC BIAS3", "AMIC4", "MIC BIAS4"
```

`sdm845-oneplus-fajita`, the other upstream OnePlus board with this codec, uses
a different permutation, and its handset input is paired with a different
supply:

```
"AMIC1", "MIC BIAS3", "AMIC2", "MIC BIAS2",
"AMIC3", "MIC BIAS4", "AMIC4", "MIC BIAS1",
"AMIC5", "MIC BIAS3"
```

A runtime sweep of `AMIC MUX0` across ADC1 to ADC4 was silent on all four under
`r34`, before the transport fix, so it did not discriminate between pads and
should be repeated now that the transport carries data.

The OxygenOS odm mixer configuration is unambiguous about the pad and the
digital chain: `handset-mic` resolves to `amic4`, which selects ADC4 through
`AMIC MUX0`, routes DEC0 into `CDC_IF TX0`, and enables
`AIF1_CAP Mixer SLIM TX0` on `SLIM_0_TX`. It says nothing about bias wiring,
because downstream sets bias in the machine driver rather than the mixer.

## Next steps

1. Repeat the ADC1-ADC4 sweep on `r35`, comparing each against a control.
2. If still silent, rebuild with the fajita bias permutation and repeat.
3. Extract the OxygenOS vendor DTB from the stock `super` image to read the
   bias wiring directly instead of choosing between two references.
4. Replace the analyzer's absolute margin with a control-relative comparison.

## Unrelated observation

Playback was re-verified after `0045`, which touches the shared SLIMbus init
path: `paplay` through PulseAudio succeeded and both TFA9874 amplifiers
reported `active=1`. No playback regression.
