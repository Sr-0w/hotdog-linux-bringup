# One hardware sensor streams real data, and what that rules out

Date: 2026-08-23

The positive control got much stronger this pass, and it collapses a large
part of the search space.

## The SEE framework is fully alive

Querying the SUID lookup for framework sensors as well as hardware ones:

| type | SUID |
| --- | --- |
| `resampler` | `d233de11b097e7b45643509e974b83c1` |
| `timer` | `d708b9787c3bb68a316563ee7e3ba813` |
| `registry` | `e12754a7007f27595e2541b4701e2275` |
| `interrupt` | `45d03dee6ee3cfb6e2461156e2f58f61` |
| `async_com_port` | `738a8c910fd127c546670b152915b0a9` |
| `device_mode` | `bcbe1be07afac0ade8115d68923fd021` |
| `suid` | `abababababababababababababababab` |
| `sars` | `7335663959f5698867456bc70a6c70ca` |

`accel`, `gyro`, `mag`, `proximity`, `ambient_light`, `wise_light`, `rgb`,
`cct`, `pressure`, `sensor_temperature`, `step_counter`, `step_detector`,
`significant_motion`, `amd`, `rmd`, `smd`, `tilt`, `free_fall`,
`device_orient`, `hall`, `remote_proc_state` and `diag` all return no SUID.

So the registry sensor, the interrupt sensor and the async com port sensor
are all up. The framework is not the problem.

## SX9324 is not just registering — it is streaming

Subscribing to the `sars` SUID returns a configuration event and then real
samples:

```
event id=768 (config)  ... 2a074e4f524d414c  -> "NORMAL"
event id=769 (sensor)  samples=0, 22, 11861, 0, 0  status=3
```

`11861` is a live capacitance reading. This is the single most useful fact
available: **the entire path works end to end for one driver** — registry
read, platform config, power rails, com-port open, GPI/I2C transfers,
interrupt plumbing, attribute publication, SUID lookup and streaming.

Every explanation that indicts shared infrastructure is therefore dead. The
QDI sensor-PD → root-PD boundary works. I2C bus instance 3 works. The GPI
DMA engine works. The rails work.

## Only one I2C address is ever addressed

Decoding the GPI transfer descriptors out of the `I2C` ULog in both curated
captures, the "GO" TREs carry the slave address in byte 1:

```
e06a2020: 04002801 ...   -> address 0x28, write
e06a2040: 00002802 ...   -> address 0x28, read
e06a2080: 00002801 ...   -> address 0x28, write
```

`0x28` is SX9324, and it is the **only** address that ever appears. The ALS
combo driver sits at `0x46` and never issues a single transaction. So it is
not being NAKed by absent hardware — it never reaches the bus at all.

## Bus topology, for the record

Read out of every served `*_platform.config`:

| sensor | bus | address |
| --- | ---: | ---: |
| SAR SX9324 (works) | 3 (I2C) | 40 = `0x28` |
| ALS/prox `alsps` | 3 (I2C) | 70 = `0x46` |
| ALS/prox `tcs3701` | 3 (I2C) | 57 = `0x39` |
| accel/gyro `lsm6dsm_0` | 2 (SPI) | 0 |
| mag `ak0991x_0` | 1 | 12 |
| mag `mmc5603x_0` | 1 | 48 |

The accelerometer and gyroscope are on **SPI bus 2**, not I2C — worth
knowing, because the working control says nothing about that bus. The `SPI`
ULog in the captures has `write=16`, essentially empty.

## Three more eliminations

**Config gating.** The `config` block of each JSON gates on `hw_platform` and
`soc_id`. The file behind the working sensor (`msmnile_sx9324_op.json`,
`hw=['MTP','Surf']`, soc 339) and the failing one (`msmnile_alsps.json`,
`hw=['MTP']`, soc 339) pass the same gate, and `msmnile_lsm6dsm.json` has a
wider list still. Gating does not discriminate.

**Candidate collision.** The full OxygenOS config set serves platform groups
for *every* candidate part — nine ALS/proximity families and five
accelerometers — where a real device would have `devinfo` select one. Tested
by moving 211 files aside, leaving exactly one candidate per category
(`alsps`, `lsm6dsm_0`, `sx9324_op_0`, `ak0991x_0`), and rebooting:

```
sars   7335663959f5698867456bc70a6c70ca
accel / gyro / mag / proximity / ambient_light / wise_light / rgb / cct   no SUID
```

No change. The registry was restored to its full 441 entries afterwards.

**The `default_sensors` attribute filter.** `default_sensors` is owned by the
`suid` sensor and lists 18 data types, each with an attribute filter —
`default_sensors.ambient_light.attr_0` is attribute id 16 (`STREAM_TYPE`)
value 1, `default_sensors.accel.attr_0` is id 19 (`RIGID_BODY`) value 0.
`sars` is not in the list, which made a filtering artefact look plausible.
It is not one: the SUID request sets `only_default_values = 0`, so no filter
is applied and the absence is real.

## The registry is read

File access times against a boot at 01:06:42 show the DSP reading the failing
driver's groups:

```
alsps_platform.als      01:06:56
alsps_platform.cct      01:06:56
alsps.als.config        01:06:58
alsps_platform.config   01:07:56
```

So the failure is not a registry read that never happens.

## Where this leaves the failure

Between "registry response received" and "com port opened", for every
hardware driver except SX9324. Everything upstream of that window is proven
working by a sensor that streams, and everything downstream is never reached
because no bus transaction is ever attempted.

One structural difference is worth carrying forward: SX9324 publishes a
static data-type string (`sars` at `0xb21e217c`), while the ALS chooses its
published type at run time from `als_type` (`0xb21d9c30`, `wise_light` versus
`ambient_light`). A driver whose type is registry-dependent cannot publish
anything until that resolution completes; a driver with a static type
publishes regardless. That asymmetry lines up exactly with which sensors have
a SUID and which do not, and is the next thing to test.
