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
| proximity operation mode | `693` |
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

The local series ends at commit
`fb21f74d442e94b48245b65dbb6809c59fedd0c2`, tree
`9bd59678620c61b8e70a03fbb146e6151ff8a5ab`. Its four commits keep the
generic Q6AFE API, bindings, drivers and hotdog DT changes separate.

A full `Image modules qcom/sm8150-oneplus-hotdog.dtb` build completed with
kernel release `6.16.0-sm8150`. Key artifacts:

| artifact | SHA256 |
| --- | --- |
| Image | `60b2750b95c8e9ba76cf0dba16b5a4263b7a44442191e1eef0b2ea39428145ee` |
| hotdog DTB | `bd8a964cc21384b6ecc838c5eefbdffd8cc9415335c07025d8e73f3fc702eb05` |
| q6afe.ko | `e9ab31255a586599142fce1df6d8cc16131ad064b4796ce60edd22f3f1b381c9` |
| q6routing.ko | `6484d18b8e6064ede86a1b5579ff4a1c05aa2f3b0faa0e63faee0565b9a65234` |
| q6hostless.ko | `cfe46e7c42997163e41e2c97983c30b416591136758f55b62a24e2b906b51c22` |
| q6elliptic.ko | `baf68693bd088c69523a498072ab4adb5af34feb46e0bd1dfde43bd828a7d7c1` |

All four modules have the exact running release vermagic. The full build reached
the real vmlinux `MODPOST`; no new unresolved symbol or driver-specific warning
was reported.

## What is not proved yet

Nothing from this build has been booted. There is no claim yet that the ADSP
accepts mode 693, that both hostless PCMs reach `RUNNING`, that the transducer
emits, or that opcode `0x0ff10204` returns events on this Linux stack.

`elliptic-proximity-smoke.py` is prepared for that future boot. It discovers
the PCM ids by exact name, arms the mixer and engine for at most five minutes,
reads only the Elliptic input device, and rolls engine, PCM processes and mixer
back in a `finally` block. A hardware run still requires a separately reviewed
boot image and the normal explicit phone lease.
