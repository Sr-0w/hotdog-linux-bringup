# The Elliptic ultrasonic proximity protocol, read out of OxygenOS

Date: 2026-08-25

The port reaches a running engine that answers version, branch, tag and
diagnostics but never sends parameter id 16, the proximity event. This is the
complete AP-side contract as OxygenOS 10.0.13 implements it, recovered from the
stock vendor partition and the downstream kernel, so that what the port sends
can be compared against it line by line.

## Where the truth lives

| component | role |
| --- | --- |
| `vendor/lib/modules/audio_q6.ko` | the stock driver, unstripped, 49 `Ultrasound *` ALSA controls |
| `vendor/lib64/hw/audio.primary.msmnile.so` | audio HAL, owns the PCMs and calibration blobs |
| `vendor/etc/mixer_paths_tavil.xml` | **the arming sequence**, control by control |
| `vendor/lib64/sensors.ssc.so` | sensor HAL, requests state through `/dev/sensor_ultrasound` |
| downstream `techpack/audio/dsp/elliptic/` | the same driver in source form |

Vendor blob identities are recorded in
[the port note](2026-08-24-elliptic-ultrasonic-proximity-port.md).

## APR transport

`elliptic_process_apr_payload` was disassembled to confirm the wire format
independently of the source:

```
ldr  w8, [x0]          ; module id
mov  w9, #0x201
movk w9, #0xf01, lsl #16   ; 0x0f010201, reject anything else
ldr  w1, [x0, #0x4]    ; parameter id
sub  w8, w1, #0x3
cmp  w8, #0x10
b.hi <illegal paramId>     ; valid range is 3..19 inclusive
ldrh w19, [x20, #0x8]  ; payload size, 16-bit
```

So the header is three little-endian words — module id, parameter id, and a
size that occupies only the low half of the third word — and the payload starts
at byte 12. Both the source (`&payload[3]`) and the near/far decode
(`data[12] == 0`) agree.

| id | meaning | seen by the port |
| --- | --- | --- |
| 3 | engine data | yes |
| 11 | calibration data | no |
| 12 | engine version | yes |
| 14 | build branch | yes |
| 15 | calibration v2 data | no |
| **16** | **sensorhub — the proximity event** | **never** |
| 17 | diagnostics data | yes |
| 18 | tag | yes |
| 19 | ML data | no |

Parameter 16 carries one meaningful byte: zero is near, non-zero is far, and
the stock driver reports it as `EV_MSC`/`MSC_RAW` with the sense inverted —
1 for near, 0 for far.

## System configuration

Everything that is not a blob is written with `ELLIPTIC_ULTRASOUND_SET_PARAMS`
(command 2) as a `{type, value, reserved}` triple. The type is the wire value
below, which is *not* the same numbering as the mixer control's register bit:

| type | name | type | name |
| --- | --- | --- | --- |
| 1 | speaker scaling | 15 | engine diagnostics |
| 2 | channel sensitivity | 16–31 | custom setting 0–15 |
| 3 | latency | 32 | suspend |
| 4 | **microphone index** | 33 | input enabled |
| 5 | operation mode | 34 | output enabled |
| 6 | operation mode flags | 35 | external event |
| 7 | component gain change | 36 | engine tag |
| 8 | calibration state | 37 | calibration method |
| 9 | engine version | 38 | debug mode |
| 10 | calibration profile | 39 | number of runs |
| 11 | ultrasound gain | 40 | context |
| 12 | log level | 41 | capture |
| 13 | build branch | 42 | input channels |
| 14 | fselection | | |

The driver's cache is zero-initialised (`{ {0}, 0 }`) and a value only reaches
the DSP when its control is written. Enabling the engine is a separate 16-byte
message, `{1, 0, 0, 0}`; the first enable of a boot also fires the version,
branch and tag triggers, which is why those three answers arrive in the port.

## The arming sequence

The audio HAL binary contains only six `Ultrasound *` control names —
calibration data, calibration ext data, calibration state, capture, gain and
ML. It owns the blobs and the PCMs. **The engine itself is armed by the mixer
paths**, in this order:

Defaults, applied at HAL init:

```
Ultrasound Event            0
Ultrasound Mode             699
Ultrasound Suspend          0
Ultrasound Enable           Off
Ultrasound Rx Port          Off
Ultrasound RampDown         Off
Ultrasound Microphone Index 0
Ultrasound Log Level        4
```

Then, per path:

| path | controls |
| --- | --- |
| `ultrasound-proximity` | `Ultrasound Enable` On, `Log Level` 4 |
| `ultrasound-proximity-output` | `QUAT_MI2S_RX Audio Mixer Ultrasound` 1 |
| `ultrasound-input` | the WCD9340 capture chain, below |
| `ultrasound-on` | `Ultrasound Rx Port` On |
| `ultrasound-screen-on` | `Ultrasound Event` 1 |

`ultrasound-proximity-input` is empty, and **no proximity path ever enables
`Ultrasound Tx Port`**. Only the RX pseudo-port is opened. That independently
confirms the port's measurement that opening pseudo-TX `0x8002` produced no
event and hung AFE shutdown: stock never does it.

`ultrasound-calibration` is a different mode entirely — Enable On, Mode 698,
Debug Mode 1, Log Level 7 — and `ultrasound-reveier-mode` is Mode 693. The
proximity mode is 699.

## The microphone is not the handset microphone

```xml
<path name="ultrasound-input">
    <ctl name="AIF2_CAP Mixer SLIM TX2" value="1"/>
    <ctl name="SLIM_2_TX Channels" value="One" />
    <ctl name="CDC_IF TX2 MUX" value="DEC2" />
    <ctl name="ADC MUX2" value="AMIC" />
    <ctl name="AMIC MUX2" value="ADC3" />
    <ctl name="SLIM_2_TX SampleRate" value="KHZ_48" />
</path>
```

Ultrasound captures **AMIC3**. `handset-mic` resolves to `amic4`. They are
different physical microphones, so the port's successful handset-microphone
capture says nothing about the ultrasound input — the two paths share only the
SLIMbus transport. `ADC3 Volume` defaults to 12 in the same file.

## What the port does not send

Comparing `q6elliptic.c` against the sequence above, the port sends the engine
enable, operation mode 699, log level, the three info triggers, external event
1, the 448-byte calibration v2 blob, and opens pseudo-RX `0x8001`. Against
stock it is missing two values that OxygenOS always writes before proximity
runs, both from the defaults block:

- **microphone index, wire type 4, value 0.** This selects the channel the
  engine listens on. The driver cache starts at zero and the value is only sent
  when the control is written, so on stock the DSP is always told explicitly;
  the port never tells it. If the DSP's own power-on default is not channel 0,
  the engine runs, produces engine data and diagnostics, and hears nothing.
- **suspend, wire type 32, value 0.**

Neither `calibration state` (type 8) nor `calibration profile` (type 10) is
sent either, though the HAL drives calibration state on stock.

This fits every symptom on record: parameter 3 arrives, so the engine is
processing; diagnostics counters advance; and no proximity transition is ever
reported. An engine listening to the wrong microphone channel would behave
exactly this way. It is a hypothesis, not a demonstration — the next test is to
send types 4 and 32 before enabling and see whether parameter 16 appears.

`Ultrasound Input` and `Ultrasound Output` — wire types 33 and 34 — are worth
ruling out explicitly: stock never writes them on any path, so the earlier
suspicion that an output or profile setting was missing does not survive
contact with the mixer file.
