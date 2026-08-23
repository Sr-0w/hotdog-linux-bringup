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

## The IMU temperature works too — parser again, and a rate ceiling

Two things were wrong at once:

- its sample payload is a **single** float (`0a 04`), not three (`0a 0c`), so
  the pattern used for accel/gyro/mag never matched it;
- above 5 Hz it answers `SNS_STD_ERROR_EVENT` (130). Its maximum rate is
  5 Hz, and 10, 25 and 100 Hz are all rejected.

```
1 Hz  ->  7 samples  ->  30.54 °C
5 Hz  -> 31 samples  ->  30.45 °C
```

## Final verification, vendor config, `helpers/ssc-verify.py`

```
accel  (m/s2)     152 ech.     0.340   -0.065    9.861
gyro   (rad/s)    151 ech.    -0.373    0.514    0.366
mag    (uT)       149 ech.  -167.925  -15.079   -1.710
temperature (C)    30 ech.    31.551
ambient_light      23 ech.  2939.784   44.000    9.000   29.000
proximity           0 ech.  -
motion_detect       0 ech.  -   (on-change; 2 events when polled separately)
sars                0 ech.  -   (on-change; 2 events when polled separately)
```

Seven of eight sensors have produced real measurements. `motion_detect` and
`sars` are on-change and only fire on a change — both answered with events
when subscribed while something was happening.

## Proximity is the one outlier

It emits **nothing at all** — not a sample, not a configuration event (768),
not an error (130). Every other sensor at least acknowledges with a config
event. Tried and unchanged:

- `SNS_STD_ON_CHANGE_CONFIG` (514)
- `SNS_STD_SENSOR_CONFIG` (513) at 1 Hz and 5 Hz
- `is_dri` switched from 1 to 0 in `alsps.prox.config`, so it polls like the
  ALS instead of waiting on the IRQ — reverted to the vendor value afterwards
- with the ambient light sensor concurrently active

It shares the TCS3701 and the `sns_alsps` driver with the ambient light
sensor, which streams normally, so the chip and the bus are not in question.

Since it is an on-change sensor, the remaining possibility that cannot be
tested remotely is simply that nothing has come near it. Confirming that needs
a hand over the top of the screen while subscribed.

## Proximity: everything remotely testable is eliminated

It emits nothing — no sample, no configuration event, no error — where every
other sensor at least acknowledges with a config event. What has been ruled
out, each by measurement:

| tried | result |
| --- | --- |
| `ON_CHANGE` (514) | silence |
| `SENSOR_CONFIG` (513) at 1 and 5 Hz | silence |
| `is_dri` 1 → 0 in `alsps.prox.config` | silence |
| `dri_irq_num` 120 → 0 and `irq_is_chip_pin` → 0 | silence |
| with the ambient light sensor concurrently active | silence |

The interrupt path was the strongest hypothesis and it is dead: all four GPIO
interrupt ULogs — `GPIOInt`, `PdcGpioInt`, `DirConnGpioInt`, `SummaryGpioInt`
— are **completely empty** (`write=0`), and the `InterruptController` log
shows ids 142, 144, 146, 148, 150 and 152 being configured, never 120. So no
GPIO interrupt is ever registered on this SLPI. But removing the interrupt
declaration entirely changed nothing, so that is a real defect and not this
one.

Its calibration is byte-identical to the OxygenOS original —
`3cm_threshold` 160, `delta` 110, `cali_goal` 50, `cali_up_thrd` 30000 — so
the thresholds are the vendor's.

It shares the TCS3701 and the `sns_alsps` driver with the ambient light
sensor, which streams 23–32 events per subscription in the same test run. The
chip, the bus, the driver and the config are therefore all exonerated.

What remains untestable from here: a proximity sensor is on-change, and
nothing has approached it. Confirming needs a hand over the top of the screen
while subscribed:

```
python3 ssc-subscribe.py 5f5f584f525031303733534354736d61 15
```

### It is not "nothing approached it" — the bus context fails

Capturing a coredump *while* a proximity subscription is open, and reading the
`I2C_error` ULog, gives a named failure:

```
bus_iface_callback : failed to initialize bus interface hw context     x6
Trying Synchronous Bus Reset:0x%08x:0x%08x                             x3
bus_iface_callback : CLEANUP ERROR: failed to start RX chan            x3
```

three different com-port contexts (`0xb0028f00`, `0xb0028f78`, `0xb0028fb4`)
— which matches the three logical instances the `sns_alsps` driver creates:
ALS, proximity and CCT.

So the silence is not an on-change sensor waiting for a hand. The proximity
instance tries to bring up its I2C com port, the bus interface hardware
context initialisation fails, the driver falls back to a synchronous bus
reset, and the RX channel never starts. No config event is ever emitted
because the instance never gets far enough to send one.

The failure is contained: subscribing to proximity does not disturb the
ambient light sensor, which returns 24 events alone and 23 with a proximity
subscription running concurrently.

That is the concrete thread to pull next — why `bus_iface_callback` cannot
initialise a hardware context for this third port when the ALS's own port on
the same address and bus works.
