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
| device `3-r12` | UCM `Mic` device on PCM 1, stock control order, working capture gains. |

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

### The handset microphone is AMIC5, not AMIC4

With transport fixed, capture carried live data but no acoustic content: a
reference tone stayed indistinguishable from the codec noise floor, and a
runtime sweep of `AMIC MUX0` across ADC1 to ADC4 was silent on all four.

The stock OxygenOS `dtbo` (`androidboot.dtbo_idx=5`) settles it. The handset
sound card is `fragment@95`, identified by `oplus,speaker-pa = "nxp"`,
`oplus,usbc-switch`, `qcom,wsa-max-devs = <0>`, and the `tfa98xx_right@34`
amplifier node immediately after it. Its `qcom,audio-routing` names each input:

| Pad | Supply | Stock role |
| --- | --- | --- |
| AMIC1 | MIC BIAS1 | - |
| AMIC2 | MIC BIAS2 | Headset Mic |
| AMIC3 | MIC BIAS4 | ANCRight Headset Mic |
| AMIC4 | MIC BIAS1 | ANCLeft Headset Mic |
| AMIC5 | MIC BIAS1 | **Handset Mic** |

So the handset microphone is AMIC5, selected on the shared `AMIC4_5` mux and
taken through ADC4. AMIC4 is an ANC input on that same mux, which is exactly
why selecting it produced a running but silent capture. Two earlier guesses
were wrong: the ClearStaff hotdog tree pairs AMIC3/AMIC4 with BIAS3/BIAS4, and
`sdm845-oneplus-fajita` uses yet another permutation. Neither is this handset.

DAPM state during capture confirms the corrected wiring powers the analogue
front end:

```
MIC BIAS1     On
AMIC5         On   in 1 out 1
AMIC4_5 SEL   On   in 1 out 1
ADC4          On   in 1 out 1
AMIC4         Off
MIC BIAS2     Off
```

## Hardware measurements

All captures were taken through the normal PulseAudio source with
[`analyze-tone-capture.py`](../../scripts/analyze-tone-capture.py).

### The level tracks the analogue gain

Ambient room sound, recorded at three `ADC4 Volume` settings. The measured
steps match the control's own step size, which is what distinguishes a real
analogue path from digital noise.

| `ADC4 Volume` | ambient RMS |
| --- | --- |
| 0 | `-87.9` dBFS |
| 8 | `-80.6` dBFS |
| 20 | `-65.5` dBFS |

### Frequency discrimination

Three tones were played in turn on the handset's own validated speakers and
each capture was measured in all three bins. Every tone is strongest in its own
bin, by 16 to 46 dB. Ambient noise from an unrelated video was present
throughout, which is why the off-diagonal figures are not at the noise floor.

| Played | 500 Hz bin | 1500 Hz bin | 3000 Hz bin |
| --- | --- | --- | --- |
| 500 Hz | **-67.1** dBFS | -83.2 dBFS | -99.0 dBFS |
| 1500 Hz | -80.5 dBFS | **-44.5** dBFS | -84.3 dBFS |
| 3000 Hz | -77.2 dBFS | -83.1 dBFS | **-37.4** dBFS |

The weaker 500 Hz result is consistent with the low-frequency rolloff of a
small handset speaker used as the source; it is not a capture defect.

### Packaged profile

After installing `device-oneplus-hotdog 3-r12` and reloading the audio service,
a capture through the packaged profile alone, with no manual mixer commands,
measured `-41.3` dBFS RMS with a peak of `0.0456` full scale.

## Playback regression check

`0045` touches the shared SLIMbus init path, so playback was re-verified:
`paplay` through PulseAudio succeeded and both TFA9874 amplifiers reported
`active=1`, returning to `active=0` on sink suspend. No regression.

## Still open

- Only the handset microphone is enabled. The headset microphone (AMIC2), the
  two ANC inputs (AMIC3, AMIC4) and the six digital microphones are described
  in the routing but have no UCM device.
- The capture gains are fixed in the profile rather than exposed as a usable
  volume control.
- Echo cancellation and any noise suppression are absent, so simultaneous
  playback and capture will feed the speakers back into the microphone.
- The analyzer's `--min-margin` is an absolute threshold and will report a
  false pass on noise. Capture checks must compare against a recorded control,
  as the tables above do.
