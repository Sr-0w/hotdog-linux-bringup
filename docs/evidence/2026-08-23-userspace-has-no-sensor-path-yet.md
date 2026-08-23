# The sensors work; userspace cannot see them yet

Date: 2026-08-23

Follow-up to the firmware fix, prompted by the screen being upside down.

## The screen was not a sensor problem

Plasma Mobile's output was configured inverted:

```
kscreen-doctor -o   ->   Rotation: 4      (Inverted, 180°)
```

Set back with `kscreen-doctor output.DSI-1.rotation.none`, now `Rotation: 1`.
Nothing to do with the accelerometer.

The SEE-side mounting was correct all along and matches the vendor exactly —
`lsm6dsm_0_platform.orient` is `x=+y, y=-x, z=+z`, byte-identical to the
OxygenOS registry backup, placement included.

## There is no SEE → userspace bridge

Measured, not assumed:

- `find /sys -name "in_accel*"` → **0 results**. No IIO accelerometer, no
  ambient light, only three PMIC ADCs and two `mxm1120` hall sensors.
- no accelerometer among input devices either — only the touchscreen, keys,
  haptics and headset jack.
- `iio-sensor-proxy` (3.9, running as PID 1641) has **no sensor file
  descriptors open** — `/proc/1641/fd` is `/dev/null` three times over.

Its D-Bus properties `HasAccelerometer=true`, `HasAmbientLight=true` and
`AccelerometerOrientation="bottom-up"` are therefore inert values, not
readings. Auto-rotation cannot work because nothing feeds it, and
`autoRotation` is set to `InTabletMode` with no data behind it.

So the sensors are functional on the DSP and reachable over QMI, and no
component in this image consumes them.

## Streaming: proven for on-change, unsolved for continuous

Proven working:

- **ambient light** — 23 events in 6 s, float payload changing sample to
  sample.
- **SAR** — config event then live capacitance, from earlier in the session.

The accelerometer, gyroscope and magnetometer are continuous sensors and need
`SNS_STD_SENSOR_CONFIG` (513) with a sample rate rather than
`SNS_STD_ON_CHANGE_CONFIG` (514). Every encoding tried is either silently
accepted with no events, or answered with `SNS_STD_ERROR_EVENT` (message 130,
code 2):

```
513 sample_rate float field 1        accepted, no events
513 sample_rate varint field 1       accepted, no events
513 sample_rate float field 2        error 130/2
513 sample_rate double field 1       accepted, no events
513 + batching field 5               accepted, no events
rates 5 / 12.5 / 25 / 50 / 200       accepted, no events
resampler 512 with target SUID       accepted, no events
attribute request (msg 1)            no events
```

**This is a client-protocol problem, not a sensor one**, and the evidence for
that is direct: under 00083 the `SPI` ULog is *full* — wrapped many times over
with transfer descriptors — and `SPI_error` is **empty**. Under 00121 the same
log held 16 bytes and one message. The LSM6DSM is reading its chip
continuously and without error; what is missing is a correctly formed request
from this end.

Worth noting the accelerometer does service requests: `ON_CHANGE` against it
returns a proper error event rather than silence, so the sensor is live and
answering.

## What a bridge would need

`iio-sensor-proxy` accepts an accelerometer exposed as an input device tagged
`ID_INPUT_ACCELEROMETER=1` by udev, publishing `ABS_X/Y/Z`. A `uinput` shim
fed from a SEE subscription would be enough for auto-rotation — once the
continuous-sensor request is solved.
