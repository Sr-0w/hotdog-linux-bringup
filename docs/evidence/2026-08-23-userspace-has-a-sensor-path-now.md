# Userspace has a sensor path now

Date: 2026-08-23

An earlier note in this series recorded that nothing in the system consumed the
sensors: no `in_accel` anywhere in `/sys`, no accelerometer among the input
devices, `iio-sensor-proxy` holding only `/dev/null`. That was read as "a bridge
must be written". **It does not: the bridge was already installed and already
running.** What was missing was the order it started in.

## The daemon already speaks SEE

postmarketOS ships `iio-sensor-proxy` 3.9 built against `libssc`, with SSC
drivers compiled in:

```
ssc_sensor_accelerometer_open_sync   ssc_sensor_light_open_sync
ssc_sensor_compass_open_sync         ssc_sensor_proximity_open_sync
```

and a udev rule that tags the FastRPC nodes for them:

```
SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp*", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-light ssc-compass"
```

which on this device resolves to
`ssc-light ssc-compass ssc-accel ssc-proximity` on both `/dev/fastrpc-adsp` and
`/dev/fastrpc-sdsp`. It talks QMI over QRTR directly to service 400 — the same
service `ssc-client.py` speaks — and it discovers our sensors by name:

```
Discovered 'accel' sensor (2286538866409242278 11115320498015681092)
  name: lsm6dsm          data-type: accel
Discovered 'ambient_light' sensor (6872316367756931376 3977614444543044961)
  name: tcs3701          data-type: ambient_light
Discovered 'proximity' sensor (6872308654097314096 3977614444543044961)
  name: tcs3701          stream-type: on-change
Discovered 'rotv' sensor (11591090518199008144 16650227176490521676)
  name: Rotation Vector
```

The earlier "no bridge" reading came from looking for an IIO or input device.
There is none and there does not need to be: this daemon bypasses both and
publishes on D-Bus as `net.hadess.SensorProxy`, which is exactly what KWin
consumes.

Light works end to end with no changes at all — `LightLevel` went from 0 to
1201.43 lux the moment a client claimed it, and tracks the room:

```
Light level sent by driver (quirk applied): 1202.857178 (unit: lux)
Light level sent by driver (quirk applied): 1190.000000 (unit: lux)
```

## Two independent faults kept the accelerometer dark

### KWin never wanted it

`/home/user/.config/kwinoutputconfig.json` carried

```json
"autoRotation": "InTabletMode",
```

and this phone has no `SW_TABLET_MODE` switch, so KWin never considers itself in
tablet mode and never enables its orientation sensor. Every restart of the
daemon produced a `ClaimProximity` from the shell and no accelerometer claim at
all. Set to `"Always"` and the claim appears.

### A claim that lands too early is accepted and lost

This is the real defect, and it is upstream's. The daemon takes its D-Bus name
**before** enumerating SEE, and enumeration is a QMI round trip per sensor.
Measured on a restart under a running KWin:

```
15:11:43.726  Starting iio-sensor-proxy version 3.9
15:11:43.774  Handling driver refcounting method 'ClaimAccelerometer'
15:11:43.801  Found SSC accelerometer
```

KWin claims 48 ms after the name appears; registration needs 75 ms. The claim is
answered, no sensor is enabled, and nothing ever enables it afterwards. Later
claims do not help: `monitor-sensor --accel` claiming afterwards produced zero
samples, while `ClaimLight` in the same client enabled the light sensor
normally — light had registered before that client connected.

The reading that fits is that the early claim occupies the 0→1 client-count
transition with no driver to enable, so every later claim is only 1→2. It is not
proven — `iio-sensor-proxy` was not read as source here — but two predictions of
it held: a third-party `ReleaseAccelerometer` does nothing, which is what a
sender-keyed client table gives, and the sensor came back only after the
claiming clients had all disconnected.

Restarting the daemon cannot win this race. KWin watches the bus name and
re-claims within milliseconds every time, and it never retries on its own.

## Ordering is the fix

The daemon must be fully enumerated before KWin exists. That is what
[the gate](../../helpers/hotdog-sensor-proxy-gate.sh) does: bring up the SLPI,
`pd-mapper` and `hexagonrpcd`, wait for SEE to publish `accel`, start the daemon,
and only return once `HasAccelerometer` is true. `iio-sensor-proxy` is removed
from the default runlevel so nothing else starts it early.

### Why the gate also brings up the SLPI

The first attempt put the wait in `/etc/local.d` and ordered the gate
`after local`, `before display-manager`. It did not work, and the reason is
worth recording: **OpenRC's `local` service declares `after *`** — it runs last,
after the display manager. A service that depends on it cannot also precede the
session; the constraint is a cycle, and OpenRC breaks it by dropping the
requested order. The observed result was the gate finishing at 29 s while KWin
had claimed at 14 s.

So the gate brings up the chain itself, early, and `/etc/local.d/50-slpi-control.start`
no longer does. That file must not restart `hexagonrpcd`: `run-hexagonrpcd.sh`
kills it before relaunching, which breaks the FastRPC attachment the gate
established, and the sensor PD does not come back without a reboot.

The `sleep 45` and paired mainline/downstream capture that used to block that
script are done and were removed from the boot path. They remain runnable by
hand as `sh /root/slpi-control.sh`.

### What it looks like when the order is right

```
18:31:11.422  Starting iio-sensor-proxy version 3.9
18:31:28.520  Found SSC accelerometer                      <- enumeration done
18:31:33.425  Handling driver refcounting method 'ClaimAccelerometer'
18:31:33.426  Enabling sensor (…) in 'continuous' mode     <- KWin's claim lands
```

Five seconds of margin instead of a 27 ms deficit, and the `Enabling sensor`
line that never appeared before. Samples follow at 25 Hz.

Enumeration took 17 s on that boot against 75 ms on a warm restart — the SLPI is
busy bringing up its drivers at the same time, so the margin is not a fixed
quantity and a fixed delay would not have been a safe substitute for waiting on
the actual property.

The cost is boot time: the session now starts around 33 s instead of 14 s,
because it waits for the sensor core. That is a deliberate trade and it is the
gate's whole purpose.

## Orientation is undefined when the phone lies flat

Worth writing down because it looks like a failure and is not. With the
accelerometer streaming, `AccelerometerOrientation` stayed `"undefined"` and the
samples read

```
Accel sent by driver (quirk applied): 1, 0, 9 (scale: 1.000000,1.000000,1.000000)
```

That is gravity on Z with the phone face-up on a desk: roughly 6° from flat,
below both of the daemon's thresholds. Correct behaviour, not a dead sensor. The
integers are the SSC driver's own rounding of m/s²; our own client reads the same
vector as `0.340, -0.062, 9.859`.

`mount-matrix` is reported by SEE as `[[1.0,0.1,0.1],[0,1,0],[0,0,1]]`, which is
not a rotation matrix; the daemon rejects it and falls back to identity. Whether
identity is right for this panel needs the phone held upright to say.
