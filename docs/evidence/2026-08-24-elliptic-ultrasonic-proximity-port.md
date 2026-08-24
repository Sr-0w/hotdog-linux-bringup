# Porting the real ultrasonic proximity path

Date: 2026-08-24

## The passive ALS workaround is not proximity

The TCS3701 trace did contain two real hand occlusions. Channel 6 changed from
1057 to 2204 during both. That was not sufficient to make it a proximity
sensor: the uncovered phone later remained at 2204 for more than eighteen
minutes in low ambient light. A simultaneous sample had c0 around 1295 and c9
around 105, confirming a dark scene rather than a hand over the sensor.

The rolling-baseline daemon therefore produced a durable false `near`. Ratios
between the other passive light channels did not fix the ambiguity: the
uncovered dark sample looked more occluded than the labelled covered intervals.
The daemon is now disabled by default. It remains available only behind
`--forcer-als-experimental` for diagnostics.

## Additional OxygenOS source material

The archive `Oneplus 7tPro.zip`, SHA256
`0aee231f1f96f70c0e47f0d5a9d234fdfa1ab41d8ed2c8db76b00e968554b465`,
contains six OnePlus firmware packages: EU, NA and IN variants of OOS 11.0.9.1
and OOS 12 F.22. Their 64 MiB `dsp.img` files are valid ext4 filesystems. They
contain normal ADSP dynamic libraries but no separately loadable Elliptic
library, consistent with the engine being part of the ADSP firmware image.
The EU OOS 11 and OOS 12 DSP partition hashes are respectively
`818b67e08baebae5b12b934ad4ef8024b3aba1be2619778792eddae8b080e8fa`
and `1ec56bbb1e84527c870d61bb66556a44b5e13f974069e0eb71b71b800697307e`.
Their ADSP library sets differ substantially, so results must always identify
which firmware generation was used rather than treating all OxygenOS releases
as byte-identical reference material.

The OOS 10.0.13 HD1913 vendor partition recovered from the MSM package supplies
the missing AP-side truth:

- `audio.primary.msmnile.so` contains the complete `ultrasound_extn` flow;
- `sensors.ssc.so` writes requested state through `/dev/sensor_ultrasound`;
- the audio HAL reads `/dev/audio_ultrasound`, applies the engine and hostless
  audio paths, then acknowledges the sensor HAL;
- `mixer_paths_tavil.xml` selects `SLIMBUS_2_TX`/AIF2 capture for the microphone
  and `QUAT_MI2S_RX` for the transducer;
- the stock kernel's `apr_elliptic.c`, Elliptic character driver and mixer
  controls provide the exact AFE protocol.

Relevant vendor blob identities are:

| file | SHA256 |
| --- | --- |
| OOS10 `vendor_a` | `7245290f9803d69671dd4979bc07bedaef293fdbe763cf8c5cdd4a3406779143` |
| `lib64/hw/audio.primary.msmnile.so` | `dc36a6f3aed605e3f24a90fed788c00c034124ba660962df8e96a6631f6988bb` |
| `lib64/sensors.ssc.so` | `610182ce9d7d2f4f923dc0de1f500fae6e19609db7c7ac733f309bfbc3047ac8` |

## Protocol recovered from the reference

The narrow contract needed by Linux is:

| item | value |
| --- | --- |
| AFE port | SLIMBUS 2 TX, `0x4005` |
| Elliptic TX module | `0x0f010201` |
| asynchronous event opcode | `0x0ff10204` |
| set-parameter id | `2` |
| sensor-hub event parameter | `16` |
| pseudo RX/TX ports | `0x8001`, `0x8002` |
| proximity operation mode | `699` |
| PCM format | mono, 48 kHz, S16_LE |

The asynchronous event starts with three little-endian words: module id,
parameter id and payload size. The first payload byte is zero for near and
non-zero for far. OxygenOS reports it as `EV_MSC/MSC_RAW`, value 1 for near and
0 for far.

## Local 6.16 implementation

A clean worktree based on the exact running-kernel source commit
`c9f60c127607a8b06395c661c38287926a2729a4` now contains:

- bounded Q6AFE APIs for vendor port parameters, pseudo-port start/stop and one
  synchronized asynchronous event handler;
- a `q6elliptic` child driver with strict event validation, input reporting,
  sysfs enable/state and partial-failure rollback;
- two no-host QDSP6 frontends matching the OxygenOS stream names;
- the stock hostless DAPM route to `QUAT_MI2S_RX` and the exact
  `SLIMBUS_2_TX` to WCD9340 `AIF2_CAP` microphone backend;
- DT schemas for the Elliptic child and hostless DAI provider.

The current local series ends at commit
`4bed42c5991bf55f1e5fb6cf0bec22d6ab59a161`, tree
`1a9d042236c5a9bd1f5ca2b7649019cffed71078`. Runtime bring-up fixed the
hostless PCM implementation, reproduced the stock startup handshake and
ordering, and corrected the proximity operation mode from the handset-only
value `693` to the global OxygenOS proximity value `699`.

A full `Image modules qcom/sm8150-oneplus-hotdog.dtb` build completed with
kernel release `6.16.0-sm8150`. Key artifacts:

| artifact | SHA256 |
| --- | --- |
| Image | `60b2750b95c8e9ba76cf0dba16b5a4263b7a44442191e1eef0b2ea39428145ee` |
| hotdog DTB | `bd8a964cc21384b6ecc838c5eefbdffd8cc9415335c07025d8e73f3fc702eb05` |
| q6afe.ko | `59fba65100bc23da9baf19a22fde3e2300099b32e7bd5329c71b436cabb43d49` |
| q6routing.ko | `60c44a7e532f22ba6559054a44589f6b114ea00700da90b7c704075b592e751f` |
| q6hostless.ko | `2e2cd8a619d5f6db084c76c69e271e6b948e36856a8500f825dbd79445f95439` |
| q6elliptic.ko | `f34ec54415803941646a6ffe3ffadb0a16e7aa857f91c193ce530403faace9a6` |
| snd-soc-sm8150.ko | `61e1901adcd6436f526e3b1928cafd347f2ba9c05caf8b879d6040aa96c6d1cd` |
| snd-soc-wcd934x.ko | `7aac12ac4ece2b8e23ee79ff7b1ebde28379e93073565a09533997b640741eb2` |

All four modules have the exact running release vermagic. The full build reached
the real vmlinux `MODPOST`; no new unresolved symbol or driver-specific warning
was reported.

## Runtime checkpoint

The candidate booted temporarily through bootloader `fastboot boot`; neither
boot slot was written. The first attempted same-kernel kexec hung before SSH
and was recovered manually to real fastboot without entering Qualcomm crash
dump mode. The bootloader path then reached a fresh Linux boot and exposed:

- the `q6elliptic`, `q6hostless`, `q6afe` and `q6routing` modules;
- the `Elliptic ultrasonic proximity` input device;
- the dedicated SLIMBUS2 capture and Quaternary MI2S playback PCMs;
- successful bounded rollback to disabled engine, closed PCMs and restored
  mixer controls after every failure.

Runtime investigation found and fixed several independent defects:

- hostless DAPM widgets were moved to their owning frontend component;
- dummy PCM constraints, copy and pointer callbacks now let both no-DMA PCMs
  reach and remain in `RUNNING`;
- the startup order now matches OxygenOS: engine, routes, then TX/RX PCMs;
- the first enable sends the stock version, branch and tag triggers; APR
  responses for parameter ids 12, 14 and 18 prove the asynchronous transport;
- operation mode 699, the active-screen event and the private 448-byte factory
  calibration are sent before proximity processing;
- the physical ultrasound microphone backend and hostless frontend are both
  mono/S16;
- the stock ADC3 gain and AIF2/DEC2/AMIC3 routing are applied and rolled back.

Repeated live replacement of the machine driver exposed a separate AFE state
bug. The DSP returned status 9 (`ADSP_EALREADY`) for the ordinary handset-mic
port after Linux had lost the corresponding local started flag. That made the
later handset-mic control captures invalid as comparisons with TX2. The Q6AFE
candidate now preserves `ADSP_EALREADY` as a distinct errno and performs one
bounded stop/reconfigure/start recovery. This recovery and the TX2 data path
must be verified from a fresh boot; audio modules must not be hot-replaced
during that validation.

The candidate was then written directly to `boot_b` from the running mainline
system because the baseline DTB has no PM8150 reboot-mode properties. The
100663296-byte partition readback matched the candidate boot image SHA256
`c85355b665190e645ed7e0aa66057bac6b8582f4bab8751bec28af80e5be8c29`
before reboot. The known rollback image remained available with SHA256
`d881abafd3496a24cd4620e5adb4f56afbf4279e6c7136ac9197af0ab726b1f6`.

Fresh-boot signal measurements corrected the last capture-format error. All
SLIMbus TX backends are mono/S16, while playback backends retain stereo/S24.
With that split the packaged handset microphone produced 188794 nonzero
samples out of 189888. One switched-route TX2 capture also appeared nonzero,
but it is not accepted as TX2 proof: isolated captures with PulseAudio stopped,
TX0 explicitly disconnected and a clean ALSA-duration close remained exact
digital zero. The earlier data can therefore have been stale TX0 data during
the route transition. `wcd934x` now rejects a zero-channel stream and
propagates SLIM prepare/enable/disable errors instead of silently returning a
successful all-zero capture.

Repeated direct TX0/TX2 probes caused automatic reboots with no pstore record;
the preceding boots logged Q6ASM responses that were not expected by the
client. Replacing a SIGTERM timeout with native ALSA duration made one isolated
close clean, but a later ADC sweep still rebooted before writing its first
sample file. The phone returns with ADSP and SLPI running and taint 512, but
active capture probing is stopped until this stream lifecycle bug is
understood.

The OxygenOS `audio_q6.ko` object was independently decoded. Its engine-enable
payload is the same 16-byte value used here; operation-mode controls use the
same 12-byte `{type, value, reserved}` layout; calibration-v2 is sent as 448
raw bytes; and proximity events are parameter id 16. The normal proximity
path opens pseudo-RX `0x8001` only, after engine activation and route setup.
Opening pseudo-TX `0x8002` produced no event and made AFE shutdown time out, so
that diagnostic branch was reverted and the phone rebooted to a clean RX-only
state.

Stock also sends a four-word ramp-down payload beginning with `-1` before
tearing down the audio paths, waits 10 ms, and only then closes the streams.
The helper now exposes and sends that exact command before closing its hostless
PCMs. This corrects the teardown contract but does not by itself establish a
sensor event.

The private calibration bytes and phone-specific paths are deliberately not
stored in Git. The driver loads them through the documented firmware name.

## Remaining blocker

Proximity is still `Partial`, not `Working`. The general SLIM capture format is
fixed and the handset microphone works, but isolated TX2 data remains exact
zero. During active tests the complete AIF2/ADC3/TX2 DAPM path is on, both
hostless PCMs run at mono/48 kHz/S16, the QUAT MI2S backend is connected, and
both TFA9874 amplifiers report unmuted. Diagnostics processing counters advance
and asynchronous parameters 3, 12, 14, 17 and 18 are observed.

Despite that, neither mode 699 nor the receiver mode 693 produced parameter 16.
This remained true during electronic transducer off/on transitions and during
several real cover/uncover gestures. The user therefore does not need to
repeat physical gestures until a further software change first produces a
plausible sensor event. The remaining work includes both the intermittent
WCD/SLIM capture lifecycle and the engine's output/profile or an as-yet missing
configuration step.

The next candidate test starts from a fresh temporary boot and first validates
the known handset microphone through its packaged UCM profile. It then runs
the guided Elliptic test without unloading any audio module. This separates a
general AFE/capture regression from the remaining TX2-specific silence.
`prepare-proximity-fastboot.sh` records the phone identity and staged module
hashes, explains the physical transition and waits indefinitely for the user
before powering off; it never invokes fastboot itself.

`elliptic-proximity-smoke.py` defaults to a guided three-cycle test, records
APR counters, waits for each physical gesture and always rolls back in a
`finally` block. A PASS still requires three observed `near`/`far` cycles.
