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
