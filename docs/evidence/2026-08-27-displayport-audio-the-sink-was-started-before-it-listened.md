# DisplayPort audio: trigger ordering was not the complete fix

Date: 2026-08-27

This note originally concluded that moving the AFE start to the PCM trigger
made DisplayPort audio work. Later testing from a fresh Plasma Mobile image
invalidated that conclusion. The ordering issue is real, but the trigger-only
change is incomplete and must not be promoted as a working driver.

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

## The experimental change

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

## Fresh-image hardware result

The r36 integration image combines the GEM ownership fix, the SM8150 DP jack
callback, the corrected upstream HPD status bits, the UCM jack binding and this
trigger experiment. It recovered the monitor's complete 384-byte EDID,
programmed 2560x1440@60 and produced a visually correct external image.

Selecting the DisplayPort output in Plasma then produced no sound. The kernel
logged repeated failures on AFE port `0x6020`:

```text
qcom-q6afe: AFE enable for port 0x6020 failed -110
q6afe-dai: fail to start AFE port 68
q6afe-dai: ASoC error (-110): at soc_dai_trigger() on DISPLAY_PORT_RX_0
```

PipeWire retried the disappearing ALSA device every few seconds and Plasma
Settings closed after the selected output vanished. The user audio service was
stopped immediately to end the retry loop. The handset remained reachable over
USB NCM and SSH.

The complete private runtime evidence is under
`/tmp/hotdog-r36-dp-audio-failure-20260828.NMFuz1`; its SHA256 index is
`1c217a45491d3999420e0ff3a20712671bcaa60c2d63bf399383f7c254c6011c`.

## Missing Qualcomm display-stream setup

Qualcomm's downstream `msm-dai-q6-hdmi-v2.c` does more than configure the HDMI
sample format. Before opening the shared DisplayPort AFE port, it calls:

```c
afe_set_display_stream(DISPLAY_PORT_RX, stream_idx, ctl_idx);
```

That helper sends both `AFE_PARAM_ID_HDMI_DP_MST_VID_IDX_CFG` (`0x102b5`) and
`AFE_PARAM_ID_HDMI_DPTX_IDX_CFG` (`0x102b6`) in one packed set-param command.
The first controller and stream both use index zero. Mainline `q6afe` sends
neither parameter, while the SM8150 ADSP implements and validates both.

## PipeWire integration and the first normal-user pass

The instance-aware Q6AFE display-stream command subsequently made one direct
ALSA stream audible. Plasma still lost the sound service because the installed
WirePlumber rule was a `main.lua.d` script. WirePlumber 0.5 no longer loads
that configuration directory, so none of the SM8150 PCM properties applied.

The replacement `wireplumber.conf.d` rule does four things:

- disables ACP's `pro-audio` profile so it does not probe the Qualcomm
  hostless PCMs;
- selects S16_LE at 48 kHz for the validated HiFi nodes;
- disables PipeWire's special `BATCH` scheduling for Q6ASM;
- disables idle suspension, because closing and reopening this legacy Q6ASM
  PCM leaves the next stream unusable.

The HDMI UCM device also conflicts with `Mic`. The resulting dock profile is
playback-only `HiFi (HDMI)`, while the normal handset profile remains
`HiFi (Mic, Speaker)`. This avoids opening an unrelated capture frontend while
the DP playback path is being prepared.

On kernel r42 (`#43`) the packaged configuration was first tested as a
temporary file. The HDMI sink reported `s16le 2ch 48000Hz`. The first
`pw-play` returned zero, the sink remained `IDLE` rather than closing after
12 seconds, and the second `pw-play` also returned zero. No AFE, Q6ASM, SMMU
or DisplayPort error was added to the kernel log during those streams.

The device package was then converted from the obsolete Lua file to the
WirePlumber 0.5 configuration and built successfully as r48. The source commit
is `bc6c041` on `bringup/hotdog-sm8150-dp-audio`. The r48 packages were not
installed on the phone: it became unreachable before the transfer began.

## The later 900e is not a logged Linux audio panic

The phone entered Qualcomm `05c6:900e` later, while the desktop session was
being stopped before the attempted r48 installation. QDL captured all 48
offered regions without reset, including four complete 2 GiB DDR segments.
The exact r42 `vmlinux` was rebuilt in the same pmbootstrap chroot; its first
64 KiB of `_text` matches DDR at physical `0x80080000`, and its Build ID is
`98e541e079d8f01117810d0309acd3807b5c7838`.

The Linux printk ring was reconstructed directly from `prb`: 1,195 records
were valid, one descriptor was in-flight, and no text block failed validation.
There is no panic, oops, SError, SMMU fault, UFS error or AFE error after the
successful audio test. The final records are two TFA9874 unmute messages at
187.7 seconds and two SLIM master-capability messages, ending abruptly at
188.318 seconds. The task list is intact with 356 tasks; Xwayland is the only
task marked `on_cpu`, while PipeWire and WirePlumber are sleeping. The `sleep`
process from the host's three-second pause before SCP is also still present.
The crash therefore happened after stopping the session but before any r48
package was transferred or installed.

Forensic hashes:

```text
segments.tsv          aa0a1c7f308d29b887bdc904a938d8d952956c0b2afb492099057072c4c02c06
QDL run.log           7bac1b2c1e9f5f572314f92115abcec867ff127e9c292ded48bd850afc811b9b
exact r42 vmlinux     140be2b008fc01777f3bc845dfc83ecfcfe5e208ca00b3781455b7b85b464309
decoded printk ring   c073ba666ba36426e51bd3546340a1493cb5fba26fba5436d5f8e55abe5f1ee4
decoded task list     d9d3e4c76585206cf85fe5d1c8e6bcedfd5a38dffa83fe112e7303c148633050
```

This proves an abrupt low-level transition, not its cause. It does not justify
attributing 900e to the new WirePlumber settings or declaring the persistent
AFE experiment safe. The raw 8 GiB dump and its decoded outputs remain private
under `logs/2026-08-28-r42-dp-audio-900e` and `r42-forensics`.

Status: **PIPEWIRE PLAYBACK PASS, PROMOTION BLOCKED**. Two normal PipeWire
streams separated by a 12-second idle interval were audible and clean. The
userspace r48 change is committed and built, but was not installed. The
persistent AFE kernel branch remains experimental until the independent 900e
and dock-disconnect risk is resolved under a later authorized phone session.
