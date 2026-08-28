# Qualcomm Q6AFE requires DisplayPort stream configuration

Date: 2026-08-28

## Failure isolated below Plasma

The r36 integration image recovers a 384-byte EDID, drives the external
monitor at 2560x1440@60 and reports the DisplayPort jack as connected.
Selecting the DisplayPort output in Plasma still produces no sound. The first
normal desktop stream fails in the Q6AFE trigger path:

```text
qcom-q6afe: AFE enable for port 0x6020 failed -110
q6afe-dai: fail to start AFE port 68
q6afe-dai: ASoC error (-110): at soc_dai_trigger() on DISPLAY_PORT_RX_0
```

PipeWire retries after the ALSA device disappears and Plasma Settings closes.
Stopping the user audio service ends that loop. This is not a Plasma routing
or UCM failure: the UCM device exists, the jack gate works, and the kernel
reaches the DSP command that times out.

The complete private r36 evidence is indexed by SHA256
`1c217a45491d3999420e0ff3a20712671bcaa60c2d63bf399383f7c254c6011c`.

## Qualcomm downstream contract

Qualcomm's public `kernel/msm-extra` tree contains the missing implementation:

- `asoc/msm-dai-q6-hdmi-v2.c` exposes `Display Port RX DEVICE IDX`, stores a
  controller and stream index, and calls `afe_set_display_stream()` before
  `afe_port_start()`;
- `dsp/q6afe.c` packs the MST stream and DPTX controller parameters into one
  set-param command;
- `include/dsp/apr_audio-v2.h` defines both payloads as two packed 32-bit
  fields: minor version followed by index.

Primary source:

- <https://android.googlesource.com/kernel/msm-extra/+/refs/heads/android-msm-redbull-4.19-android11-qpr2/asoc/msm-dai-q6-hdmi-v2.c>
- <https://android.googlesource.com/kernel/msm-extra/+/7d02ebed32f03421d272eae1831dda37f24f2147/dsp/q6afe.c>
- <https://android.googlesource.com/kernel/msm-extra/+/48696dd1a1e9bf42b32045253819137717020aa2/include/dsp/apr_audio-v2.h>

The relevant identifiers are:

```text
AFE_PARAM_ID_HDMI_DP_MST_VID_IDX_CFG = 0x000102b5
AFE_PARAM_ID_HDMI_DPTX_IDX_CFG       = 0x000102b6
```

Both payloads use minor version `1`. Qualcomm supports controller indices
zero and one and stream indices zero and one. Mainline currently exposes one
DisplayPort AFE DAI, so the first implementation uses controller zero and
stream zero without adding a userspace control that cannot select another
Linux DAI.

## SM8150 firmware confirmation

The exact OxygenOS SM8150 `adsp.mbn` implements both parameters in
`AFEHdmiOutputDrv.cpp`. Its strings and Hexagon dispatch code validate the
parameter IDs, versioned payloads, DPTX index, interface and MST handling.
OxygenOS did not provision this handset's product audio policy for DisplayPort,
so it is not a user-visible stock feature to copy. The Qualcomm driver and ADSP
nevertheless provide an exact hardware protocol rather than a guessed payload.

## Mainline implementation

Patch `0027` adds `q6afe_port_set_display_stream()`. Qualcomm selects the
instance-aware interface for this firmware, so it emits one
`AFE_PORT_CMD_SET_PARAM_V3` whose 48-byte payload is:

```text
16-byte v3 parameter header + 8-byte MST stream payload
16-byte v3 parameter header + 8-byte DPTX controller payload
```

Each v3 header carries module instance zero. The first r37 candidate used v2
headers. Under an automatic PipeWire retry loop it produced 41 apparent
display-config successes and three timeouts, followed by 44 device-start
timeouts. Qualcomm's actual helper chooses v3 whenever module instances are
supported; the v2 result therefore does not validate the payload and is
superseded by this direct v3 implementation.

Patch `0028` sends controller zero and stream zero for `DISPLAY_PORT_RX`, then
the existing HDMI format and AFE start command. The start remains in the PCM
trigger because mainline ASoC prepares the CPU DAI before `hdmi-codec`; the DP
controller audio engine must be enabled before the AFE start waits on it.

The earlier unconditional stop experiment is removed. Qualcomm does not use
it, and it can add another timeout without supplying the missing routing data.

## Hardware result

The instance-aware implementation was packaged as kernel revision r38 and
booted on the phone as:

```text
6.17.0-sm8150-hotdog-clean #39-oneplus-hotdog-mainline617-clean
```

With Plasma, PipeWire, WirePlumber and callaudiod stopped, one bounded ALSA
playback through `MultiMedia1` succeeded. The test selected only
`DISPLAY_PORT_RX Audio Mixer MultiMedia1`, played a 48 kHz stereo S16_LE WAV
with `aplay -D hw:0,0`, and returned zero. The 440 Hz tone was physically
heard from the monitor. Stopping playback and unplugging the dock produced no
new kernel error, APR retry, timeout or loss of SSH.

This proves the following kernel path on the tested hardware:

```text
Q6ASM MultiMedia1 -> Q6 routing -> Q6AFE DisplayPort -> DPTX -> monitor
```

The same boot still fails under the normal Plasma audio stack. PipeWire
selects the DisplayPort sink, then `AFE_PORT_CMD_DEVICE_START` repeatedly
times out with `-110`; Plasma Settings consequently reports that its
connection to the sound service was lost. Adding `JackHWMute "Speaker"` to
the UCM HDMI device correctly leaves only the available HDMI sink in the
active profile, but does not change this failure.

The kernel transport is therefore hardware-validated, while normal-user
playback remains blocked by a difference between the successful direct ALSA
stream and the PipeWire stream lifecycle or parameters. A literal no-sound
result from Plasma must not be used to revert the DisplayPort stream
configuration protocol.

Private evidence directories:

```text
r38-v3-headless-single.15XoPG
r38-r47-plasma-topology.VXe1rc
r38-r47-plasma-failure.wYxejH
```

The directories contain local runtime data and are intentionally not part of
the public repository.

## Restart failure isolation

A second headless test reused the same r38 boot, `MultiMedia1` route, 48 kHz
stereo parameters, connected monitor and active DP jack. It first appeared to
isolate the ALSA frontend format:

```text
S16_LE: aplay rc=0, no new kernel message, tone physically heard
S24_LE: aplay rc=1, write error, AFE port 0x6020 start timed out (-110)
```

That interpretation was superseded by the next clean-boot tests. After an
S16_LE first stream passed, an explicit S24-to-S16 ALSA plug stream failed.
On another fresh boot the same S24-to-S16 stream passed as the first stream,
then an identical second S24-to-S16 stream failed. The slave hardware format
was printed as S16_LE in both cases.

The actual invariant is therefore first start versus restart, not S16 versus
S24. A successful stream leaves enough stale AFE or DPTX state for the next
`AFE_PORT_CMD_DEVICE_START` to time out. This matches the Plasma failure: the
sound server probes or opens the device before the user requests playback,
then the visible stream is a restart.

The S16 backend candidate remains on the separate
`bringup/hotdog-sm8150-dp-audio-s16` branch and is not eligible for merging.
It did not fix a second stream. The next gate is to verify the stop callback,
return value and AFE/DPTX shutdown ordering against Qualcomm downstream.

Private A/B evidence directory:

```text
r38-dp-format-ab-20260828T193405
r39-clean-first-plug-s24.PyDaFw
r39-parameterized-pcm.*
```

## Offline gate

- `git diff --check`: PASS
- `checkpatch.pl --strict`: 0 errors, 0 warnings
- `q6afe.o` with `ARCH=arm64 LLVM=1 W=1`: PASS
- `q6afe-dai.o` with `ARCH=arm64 LLVM=1 W=1`: PASS

Object SHA256 from the isolated build:

```text
q6afe.o      9fceffe50461683523219de27a91282b9835ac43ae742ae18a574421692adf23
q6afe-dai.o  d91a117281cbc0f492bac949b942b5299531c8f0e8aa506a6b58850a0a410eef
```

Status: **KERNEL HARDWARE PASS, NORMAL-USER PLAYBACK PARTIAL**. Direct ALSA
playback and clean unplug pass. PipeWire/Plasma playback still requires a
separate, bounded fix and must not be reported as working yet.
