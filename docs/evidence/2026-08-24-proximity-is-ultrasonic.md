# Proximity on this phone is ultrasonic

> The identification remains correct; the implementation work described as
> remaining below is now complete and package-owned.

Date: 2026-08-24

Settled, from the OxygenOS HAL itself. The TCS3701's proximity sub-sensor is
not this device's proximity sensor, and never was — which is why two days of
work could not make it report.

## The decision, in the vendor HAL

`Proximity::GetUseProximityType()` in `/vendor/lib64/sensors.ssc.so` branches on
`_screenState` and then on per-state availability flags. The constructor names
them in its own log lines:

```
+0x2f2  _screenOnUseUltrasound     +0x2f5  _screenAodUseUltrasound
+0x2f3  _screenOnUseInfrared       +0x2f6  _screenAodUseInfrared
+0x2f4  _screenOnUseTP             +0x2f7  _screenOffUseUltrasound
                                   +0x2f8  _screenOffUseInfrared
```

and sets all three ultrasound flags unconditionally:

```
75e70:  orr  w8, wzr, #0x1
75e74:  strb w8, [x19, #0x2f2]     ; _screenOnUseUltrasound  = 1
75e78:  strb w8, [x19, #0x2f5]     ; _screenAodUseUltrasound = 1
75e7c:  strb w8, [x19, #0x2f7]     ; _screenOffUseUltrasound = 1
```

`0x75e70` is where both the `pthread_create` success path and the error-logging
path converge, so the write is not conditional on anything.

`GetUseProximityType` tests ultrasound **first** in each of the three screen
states and returns immediately when set. With all three flags hardcoded to one,
it always selects ultrasound. The infrared and touch-panel branches are dead
code in this build.

## Where the ultrasonic sensor lives

Not on the sensor DSP. The OPLUS downstream kernel puts it on the **audio** DSP:

- `techpack/audio/dsp/elliptic/` and `apr_elliptic.c` — the Elliptic Labs
  ultrasonic stack, reached over APR;
- `drivers/misc/audio_sensor.c`, registering the two misc devices the HAL
  opens, `audio_ultrasound` and `sensor_ultrasound`, under `CONFIG_AUDIO_SENSOR`;
- `/proc/ultrasound/event_num`, which `sensors.ssc.so` reads.

The transducer is the earpiece speaker and a microphone. There is no dedicated
proximity part to probe, which is why bus scans, rail votes, interrupt lines and
registry permutations were all searching for something that does not exist.

## What this retires

Every proximity hypothesis in this repository that assumed a hardware or
configuration fault in `sns_tcs3701`. The sub-sensor is published because the
TCS3701 has the capability and the driver registers it unconditionally; nothing
requests it because OxygenOS never requests it either. Its behaviour — a UID and
full attributes, no client request, no configuration event, no bus traffic, no
error — is the correct behaviour of a sensor nobody uses.

It also explains the measurement that never fitted: covering the sensor roughly
triples the light sensor's raw channels, so the optics work. They are simply not
what decides "near" on this phone.

## What making proximity work now requires

A different subsystem, with its own bring-up:

1. the ADSP running the Elliptic firmware — the ADSP itself is already up on
   this port;
2. an APR client equivalent to `apr_elliptic.c`, which is out-of-tree OPLUS code
   sitting in the audio techpack;
3. the character devices the userspace expects, or a different userspace
   contract altogether, since `iio-sensor-proxy` expects proximity from SEE.

That is a project, not a fix. But it is a defined one, against a known
reference, which is a different position from "the sensor is silent and nobody
knows why".
