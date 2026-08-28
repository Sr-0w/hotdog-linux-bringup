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

Patch `0027` adds `q6afe_port_set_display_stream()`. It emits one
`AFE_PORT_CMD_SET_PARAM_V2` whose 40-byte payload is:

```text
12-byte v2 parameter header + 8-byte MST stream payload
12-byte v2 parameter header + 8-byte DPTX controller payload
```

Patch `0028` sends controller zero and stream zero for `DISPLAY_PORT_RX`, then
the existing HDMI format and AFE start command. The start remains in the PCM
trigger because mainline ASoC prepares the CPU DAI before `hdmi-codec`; the DP
controller audio engine must be enabled before the AFE start waits on it.

The earlier unconditional stop experiment is removed. Qualcomm does not use
it, and it can add another timeout without supplying the missing routing data.

## Offline gate

- `git diff --check`: PASS
- `checkpatch.pl --strict`: 0 errors, 0 warnings
- `q6afe.o` with `ARCH=arm64 LLVM=1 W=1`: PASS
- `q6afe-dai.o` with `ARCH=arm64 LLVM=1 W=1`: PASS

Object SHA256 from the isolated build:

```text
q6afe.o      3cb04202e368832cbd19cc2862f4e6a513e7b3f3b0e8d88669dfb67da503f594
q6afe-dai.o  d91a117281cbc0f492bac949b942b5299531c8f0e8aa506a6b58850a0a410eef
```

Status: **OFFLINE PASS, HARDWARE NOT YET VALIDATED**. Promotion requires a
fresh boot followed by one bounded normal-user playback, successful stop, and
dock unplug without `-110`, APR retry loops or loss of SSH.
