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
`648c410d4e0392869ea1ccb68c88747ad7e824b3`, tree
`7d89c48a57d7381bda4d818cc5b72f0d62e73629`. Runtime bring-up fixed the
hostless PCM implementation, reproduced the stock startup handshake and
ordering, and corrected the proximity operation mode from the handset-only
value `693` to the global OxygenOS proximity value `699`.

A full `Image modules qcom/sm8150-oneplus-hotdog.dtb` build completed with
kernel release `6.16.0-sm8150`. Key artifacts:

| artifact | SHA256 |
| --- | --- |
| Image | `60b2750b95c8e9ba76cf0dba16b5a4263b7a44442191e1eef0b2ea39428145ee` |
| hotdog DTB | `bd8a964cc21384b6ecc838c5eefbdffd8cc9415335c07025d8e73f3fc702eb05` |
| q6afe.ko | `e9ab31255a586599142fce1df6d8cc16131ad064b4796ce60edd22f3f1b381c9` |
| q6routing.ko | `60c44a7e532f22ba6559054a44589f6b114ea00700da90b7c704075b592e751f` |
| q6hostless.ko | `2e2cd8a619d5f6db084c76c69e271e6b948e36856a8500f825dbd79445f95439` |
| q6elliptic.ko | `b571f3faa40e8fa48659b2deaa6a673e8002e4d9506307ca2da3410329b3d767` |
| snd-soc-sm8150.ko | `88e22a04e69b1cc4bc1653657c184ec21ed673d19d61721c052e8f2521176fb1` |

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

The private calibration bytes and phone-specific paths are deliberately not
stored in Git. The driver loads them through the documented firmware name.

## Remaining blocker

Proximity is still `Partial`, not `Working`. Repeated guided top-edge cover
tests have produced no parameter-id 16 sensorhub event. The ADSP does return
version/branch/tag and diagnostics, and its processing counters increase while
the two hostless PCMs run. Direct AP capture confirms that the remaining fault
was narrowed to the physical SLIMBUS2 microphone data path. The first direct
capture used mono/S24 and returned only zeros while the complete WCD9340 DAPM
chain was powered. Re-reading the exact OxygenOS mixer configuration showed
that this format was wrong: stock sets `SLIM_2_TX SampleRate=KHZ_48` and
`Channels=One`, but unlike the transducer's `QUAT_MI2S_RX` path it never sets
`SLIM_2_TX Format=S24_LE`. The WCD9340 capture DAIs also advertise S16. The
next candidate therefore restores mono/S16 and must be evaluated on a fresh
AFE state before the silence can be called a hardware-path failure.

The next candidate test starts from a fresh temporary boot and first validates
the known handset microphone through its packaged UCM profile. It then runs
the guided Elliptic test without unloading any audio module. This separates a
general AFE/capture regression from the remaining TX2-specific silence.

`elliptic-proximity-smoke.py` defaults to a guided three-cycle test, records
APR counters, waits for each physical gesture and always rolls back in a
`finally` block. A PASS still requires three observed `near`/`far` cycles.
