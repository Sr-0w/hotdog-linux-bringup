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

## The IIO proximity device

The driver now registers an IIO proximity device beside the input one. The
input device stays because the test tooling reads it; removing it is a separate
decision.

```
iio:device5   name = elliptic_proximity
              in_proximity_raw
              events/in_proximity_thresh_rising_en
              events/in_proximity_thresh_falling_en
```

A read taken before the engine has reported anything returns `-EAGAIN`
(`Resource temporarily unavailable`) rather than a fabricated `far`. The engine
only speaks while the ultrasound audio path is armed, and an invented far
reading would be indistinguishable from a real one — which is precisely the
failure mode of the SEE proximity sub-sensor this replaces. With the engine
armed the same read returns 0, and both event enables can be set and read back.

udev tags the node from
[`62-hotdog-elliptic-proximity.rules`](../../udev/62-hotdog-elliptic-proximity.rules):

```
IIO_SENSOR_PROXY_TYPE=iio-poll-proximity
PROXIMITY_NEAR_LEVEL=1
```

The level is 1 because the engine reports a decision, not a distance.
`iio-sensor-proxy` refuses a proximity sensor whose threshold it cannot
determine: *Found proximity sensor but no PROXIMITY_NEAR_LEVEL udev property*.

## What remains: two proximity sensors, and the wrong one wins

`HasProximity` was already `true` before any of this, and `ProximityNear`
already `false`. That reading comes from SEE, whose TCS3701 proximity
sub-sensor is published but never emits — a sensor that answers "nothing near"
forever. On this device `iio-sensor-proxy` is linked against libssc and holds
fourteen QMI sockets with no file descriptor on IIO sysfs, so it is that dead
sub-sensor it reports, not the working one.

The IIO device is therefore complete and unused. Resolving it means either
dropping the SEE proximity sub-sensor so SSC has nothing to offer, or changing
which source `iio-sensor-proxy` prefers. The first is not a free action: `.prox`
and `.als` are declared in the same `tcs3701` configuration, and the ambient
light sensor on that chip works and is calibrated. Neither has been done.

## Why a binary channel read far forever

With the IIO device registered and the udev level set, the engine produced
thirty clean transitions over 123 seconds while `ProximityNear` never moved
once. The chain broke on arithmetic, in `iio-poll-proximity`:

```c
near_level *= (last_level > near_level) ? 0.9 : 1.1;
is_near = (prox > near_level);
```

The hysteresis is multiplicative, applied either side of the near level. With
a channel reporting 1 for near and `PROXIMITY_NEAR_LEVEL=1`, the threshold is
1.1 and `1 > 1.1` is never true. The sensor reads far for the life of the
process, and nothing in any log says why.

A proximity channel is a magnitude, not a boolean, and it needs headroom on
both sides of its threshold. The driver now reports 2 for near and 0 for far,
which is the smallest pair that clears the upper mark and stays under the lower
one, so the hysteresis works as designed in both directions.

`Ultrasound ML`, the 432-byte control, is bidirectional on stock and the audio
HAL references it. This port neither reads nor writes it, and which direction
OxygenOS uses has not been determined.
