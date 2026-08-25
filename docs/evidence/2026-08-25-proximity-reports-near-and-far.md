# Proximity reports near and far

Date: 2026-08-25

The Elliptic engine now sends parameter 16. The cause of its silence was that
nothing ever told the DSP which microphone channel to listen on.

## The change

`q6elliptic` sends two values before enabling the engine, both taken from the
defaults block of the stock `mixer_paths_tavil.xml`:

| wire type | value | control on stock |
| --- | --- | --- |
| 4 | 0 | `Ultrasound Microphone Index` |
| 32 | 0 | `Ultrasound Suspend` |

The stock driver's configuration cache is zero-initialised and a value only
reaches the DSP when its control is written, so OxygenOS always states the
channel explicitly. This port never did, leaving the DSP on its own default.
See [the protocol note](2026-08-25-elliptic-protocol-from-oxygenos.md).

## Before and after

Same phone, same kernel release, same operation mode 699.

| run | last parameter | proximity events |
| --- | --- | --- |
| 2026-08-24, before | 3, engine data | none |
| 2026-08-25, three guided runs | **16** | near on 2 of 3 covers |
| 2026-08-25, recorded run | **16** | 5 complete cycles |

## The recorded run

Two minutes, phone held to the ear and removed at the operator's own pace,
timestamps relative to the moment the engine was armed:

```
t=  0.20 far      (initial state at arming)
t= 51.82 near     t= 55.85 far
t= 73.47 near     t= 76.04 far
t= 78.35 near     t= 79.04 far
t= 85.44 near     t= 87.53 far
t= 91.20 near     t= 99.56 far
```

Eleven transitions, strictly alternating, no missed state and no flapping.
Near was held between 0.69 s and 8.36 s, median 2.57 s, and far followed each
removal within seconds. Nothing arrived in the first 51 s, before the first
gesture.

**This log cannot give a latency.** It records when the state changed, not when
the gesture happened, so the intervals above are the operator's pace, not the
engine's response time. Measuring latency needs a gesture marker the record
mode deliberately does not have.

## It does not respond to a cardboard box

Tested with a flat box, proximity does not trigger. Held to a face, it triggers
every time. That is the engine behaving as designed rather than a defect: this
is a classifier for one situation, a head against the earpiece during a call,
not a rangefinder. It carries a 432-byte trained model (`ELLIPTIC_ML_DATA_SIZE`,
parameter 19) and a 448-byte per-unit factory calibration, its modes are named
`receiver` (693) and proximity (699), and its emitter is the earpiece. A flat
box returns a clean specular echo; a head returns a diffuse multi-path one. The
model accepts the second and rejects the rest, which is what keeps a phone in a
pocket from blanking its screen.

An earlier guess that the missing far transitions came from asymmetric
confirmation windows is **not supported by this data** — far follows within
seconds here. The guided runs failed because they were performed with the box.

## What remains

The driver reports `EV_MSC`/`MSC_RAW`, 1 for near and 0 for far, which is the
OxygenOS convention that `send_event_to_user` implements downstream. It is not
a Linux proximity interface: there is no IIO proximity channel, and nothing
consumes `/dev/input/event4`. The screen therefore does not blank during a
call. Standard integration — an IIO proximity device or an
`iio-sensor-proxy`-visible source — is the remaining work.

`Ultrasound ML`, the 432-byte control, is bidirectional on stock and the audio
HAL references it. This port neither reads nor writes it, and which direction
OxygenOS uses has not been determined.
