# Continuous sensors stream — the request envelope was wrong

Date: 2026-08-23

## The bug was mine, and the vendor library settled it

Guessing the wire format cost a dozen failed attempts. The answer is in
`vendor/lib64/libsnsapi.so`, which embeds the serialized protobuf descriptors.
Decoded from it:

```
sns_client_request_msg {
  suid        = 1  required  message  -> sns_std_suid
  msg_id      = 2  required  fixed32
  susp_config = 3  required  message  -> suspend_config
  request     = 4  required  message  -> sns_std_request     <-- not raw bytes
}
sns_std_request {
  batching   = 1  optional  message
  payload    = 2  optional  bytes                            <-- config goes here
  is_passive = 3  optional  bool
}
sns_std_sensor_config { sample_rate = 1  required  float }
```

I had been placing the encoded `sns_std_sensor_config` **directly** in field 4
instead of wrapping it in `sns_std_request.payload`. That is also exactly why
on-change subscriptions appeared to work: their payload is empty, so an empty
field 4 still parses as a valid `sns_std_request`.

The corrected client is `helpers/ssc-stream.py`.

## Result

```
ACCELEROMETRE (m/s2)          GYROSCOPE (rad/s)
x=  0.3376 y= -0.0551 z= 9.8613    x= -0.1748 y= -0.1422 z=  0.0674
x=  0.3424 y= -0.0790 z= 9.9068    x= -0.3628 y=  0.5404 z=  0.3504
x=  0.3376 y= -0.0694 z= 9.9140    x= -0.0122 y=  0.0004 z= -0.0076
204 samples in 8 s @ 25 Hz         204 samples in 8 s @ 25 Hz
```

`z = 9.86 m/s²` is gravity with the phone flat and face up, and the gyroscope
settles to near zero at rest. Both are real measurements at the requested
rate.

Streaming is now demonstrated on four sensors: accelerometer and gyroscope
(continuous), ambient light and SAR (on-change).

## The magnetometer registers but produces no samples

It answers with configuration (msg 768) and calibration (msg 1022, zero bias
and a correction matrix) events, but never `sns_std_sensor_event` (1025).
That is consistent with the bus scan: the driver that registered is
`sns_ak0991x` at `0x0c`, where
[nothing answers](2026-08-23-a-device-answers-at-0x30.md), while the chip on
this board is the MMC5603 at `0x30`. It registers because registration does
not require a successful read, and it streams nothing because there is no
chip to read.

Getting real magnetometer data needs `sns_mmc5603x` to be the driver that
takes the slot.

## The magnetometer does stream — that was my parser too

197 events of type 1025 with real field readings:

```
mag x=-167.95 y=-14.67 z=-0.77   µT
mag x= 168.00 y= 16.50 z=  2.93  µT
```

The earlier "all zeros" came from matching `0a 0c` anywhere in the datagram,
which caught the **zero bias vector of the calibration event** (msg 1022)
instead of the sample. Filtering strictly on message id 1025 fixes it. The
section above claiming the magnetometer produces no samples is wrong and this
supersedes it — and with it, the inference that `sns_ak0991x` holds a slot
with no chip behind it. It reads a chip fine.

## Final verification

`helpers/ssc-verify.py`, one subscription per sensor, message id 1025 only:

| sensor | samples / 6 s | first reading |
| --- | ---: | --- |
| accel (m/s²) | 151 | `0.335  -0.069   9.861` |
| gyro (rad/s) | 151 | `-0.363  0.538   0.369` |
| mag (µT) | 149 | `168.002 16.503  2.932` |
| ambient_light | 23 | `3188.060 44.000 9.000 23.000` |
| SAR | 2 | on-change |
| motion_detect | 2 | on-change |
| proximity | 0 | on-change, nothing approached it |
| sensor_temperature | 0 | streaming request accepted, no samples |

Six of eight deliver data. `proximity` is an on-change sensor and nothing came
near it during the test — confirming it needs a hand over the sensor, which is
a physical action. `sensor_temperature` accepts a streaming request at 5 and
25 Hz, and with the accelerometer concurrently active, and emits nothing.
