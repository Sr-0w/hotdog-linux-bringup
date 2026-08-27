# DisplayPort audio: the sink was started before it was listening

Date: 2026-08-27

Audio now reaches a monitor over DisplayPort on this handset. It never had
before, and the reason it did not is an ordering problem in ASoC rather than
anything specific to the phone.

## The ordering

`snd_soc_pcm_dai_prepare()` walks `for_each_rtd_dais()`, which is CPU DAIs
first and codec DAIs after. On the DisplayPort link that means:

1. CPU DAI `q6afe` → `q6afe_dai_prepare()` → `q6afe_port_start()`
2. codec DAI `hdmi-codec` → `msm_dp_audio_prepare()` → `MMSS_DP_AUDIO_CFG` BIT(0)

so the AFE port was started into a controller whose audio engine was still off.
The DSP did not refuse the command, it never answered it:

```
qcom-q6afe: AFE enable for port 0x6020 failed -110
q6afe-dai: fail to start AFE port 68
q6afe-dai: ASoC error (-110): at snd_soc_dai_prepare() on DISPLAY_PORT_RX_0
```

And because the CPU prepare failed, step 2 never ran at all. The engine was
never enabled, the port stayed half-open, and the next attempt found it that
way:

```
qcom-q6afe: recovering already active AFE port 0x6020
```

That recovery path only triggers on `-EALREADY`. A port that answers nothing
gets `-ETIMEDOUT`, which it does not handle.

## The change

Keep the port configuration and the start together, and move both to a
`trigger` callback, which runs after every prepare. HDMI takes the same path for
the same reason — its sink is programmed by another driver too.

Three measurements, five or six playbacks each, routing `MultiMedia1` to
`DISPLAY_PORT_RX`:

| kernel | playbacks | `-110` logged |
| --- | --- | ---: |
| start in prepare | 0 | every attempt |
| start in trigger, config still in prepare | 5/5 | 8 |
| config moved to trigger as well | 5/5 | 4 |
| unconditional port stop before start | 6/6 | 2 |

Raising `TIMEOUT_MS` from 3000 to 10000 halved the failures at one point too,
which is why the timeout is *not* the explanation: if it were merely slow, a
longer wait would have removed them entirely rather than halving them. That
experiment was reverted; the value is global to every AFE command and has no
business changing for this.

## Why the retry was not enough

An earlier version waited for the timeout and then closed and restarted the
port. Playback worked, but each attempt cost three seconds, and a sound server
does not wait that long: Plasma reported *"connection to the sound device
lost"* and tore the node down, which is what made the settings module look like
it was crashing. It was not crashing — the captured session log shows it
unloading its libraries one by one, a clean exit.

Stopping the port unconditionally before starting it costs nothing on a stopped
port and removes the wait.

## Two things that were not the DisplayPort path

**The audio backend was PulseAudio.**
`postmarketos-base-ui-audio-backend-pulseaudio` was installed instead of the
PipeWire one, and its daemon held `/dev/snd`, so WirePlumber saw *no devices at
all* — no sink, no source. That is why Plasma offered no output and no input,
and it had nothing to do with 6.17 or with DisplayPort. After switching to
`postmarketos-base-ui-audio-backend-pipewire`:

```
Devices:  51. Built-in Audio                     [alsa]
Sinks:    55. Built-in Audio Internal speakers
Sources:  56. Built-in Audio Internal microphone
```

**UCM had no DisplayPort device.** `HiFi.conf` declared only `Speaker` and
`Mic`, so even a working AFE port would have given Plasma no sink to offer. It
now declares an `HDMI` device that conflicts with `Speaker` — they share front
end `MultiMedia1` on PCM 0 and only the back end differs, so enabling one has to
hand the front end over rather than adding a second sink. WirePlumber exposes
whichever is active.

## Still open

Two starts in six still log `-110`. Playback survives them, but the cause is not
understood: the DSP keeps state for this port across a stream Linux believes it
released, and an unconditional stop reduces that without eliminating it.

The `qcom_snd_dp_jack_setup()` that sm8250 does for hotplug reporting is still
missing here, so the DisplayPort device is offered whether or not a monitor is
attached.
