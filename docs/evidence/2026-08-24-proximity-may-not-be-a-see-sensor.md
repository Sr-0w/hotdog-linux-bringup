# Proximity may not be a SEE sensor on this device

> Confirmed and superseded: OxygenOS uses the Elliptic ADSP path, now validated
> under Linux. See [the final protocol](2026-08-25-elliptic-protocol-from-oxygenos.md).

Date: 2026-08-24

Two days of work assumed the TCS3701's proximity sub-sensor is this phone's
proximity sensor and that something was preventing it from reporting. The
OxygenOS client, recovered from the vendor partition, suggests the assumption
itself is what was wrong.

## What the reference client contains

`/vendor/lib64/sensors.ssc.so` — the HAL that talks to SEE — knows **four**
proximity implementations and chooses between them at run time:

```
oneplus.sensor.infrared.proximity        Infrared_Proximity, InfraredEventCallback
oneplus.sensor.tp.proximity              GetTpProximityEvent, FusionTpProximityCallbackDefault
oneplus.sensor.ultrasound.proximity      GetUltrasoundProximityEvent, IsUseUltrasound
oneplus.sensor.prox_motion               persist.vendor.sensors.proximity.using_motion
```

with `GetUseProximityType` and `get_available_prox_sensors` selecting among
them, and the ultrasound path reaching `/dev/sensor_ultrasound`,
`/dev/audio_ultrasound` and `/proc/ultrasound/event_num`.

## The ultrasound path is real on this platform

The OPLUS downstream kernel carries it:

- `techpack/audio/dsp/elliptic/` and `apr_elliptic.c` — Elliptic Labs ultrasonic
  sensing, running on the **audio** DSP through APR, not on the sensor DSP;
- `drivers/misc/audio_sensor.c`, which registers exactly the two misc devices
  the HAL opens, `audio_ultrasound` and `sensor_ultrasound`, under
  `CONFIG_AUDIO_SENSOR`, `default y` inside `OPLUS_FEATURE_MM_ULTRASOUND`.

The touch-panel path is a dead end here: `sec_drivers_s6sy761.c` — this phone's
touchscreen — mentions proximity only in a debug string and implements none of
the `apk_proximity_*` hooks the OPLUS touch core defines.

## Why this fits everything observed

The SEE proximity sub-sensor behaves exactly like a sensor **nobody asks for**:

- it publishes a UID and a full attribute set, because the driver registers it
  unconditionally — the TCS3701 has the capability whether or not the board
  uses it;
- the driver asks the framework for a client request against
  `amsTCS3701PROX__` and gets none, while getting one for the light sensor in
  the same call;
- no configuration event, no I2C traffic, no error — the shape of something
  never enabled rather than something failing.

And it explains the one measurement that never fitted a hardware fault: the
chip plainly responds to a finger, since covering it roughly triples the light
sensor's raw channels on the same die. The optics work. They are simply not
what this phone uses to decide "near".

## What is established and what is not

**Established:** the four implementations and the selector exist in the HAL; the
ultrasonic stack exists in the downstream kernel and registers the devices the
HAL opens; the touch-panel path is unimplemented for this touchscreen; the SEE
proximity sub-sensor is never given a client request.

**Not established:** that this specific unit selects the ultrasonic path. That
choice is made at run time by `GetUseProximityType`, and the inputs it reads
have not been traced. The vendor `build.prop` names no proximity property, and
`/persist/sensors/sensors_list.txt` lists a bare `proximity` without saying
which kind.

Disassembling `GetUseProximityType` in `sensors.ssc.so` — ARM64, and on the
workstation — would settle it. That is the next step, and it is the first time
this question has had a decidable answer available without diag.

## What it would mean

If the selector picks ultrasound, then there is no SEE proximity bug on this
port: the sensor is silent because it is not the device's proximity source, and
proximity would have to come from the Elliptic stack on the audio DSP — a
different subsystem entirely, with its own firmware and its own bring-up.

The honest statement today is that the sensor count is ten of eleven **SEE**
sensors, and that the eleventh may not be a SEE sensor at all.
