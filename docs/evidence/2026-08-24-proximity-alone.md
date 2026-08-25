# Proximity, alone

> Historical isolation checkpoint. Proximity is now Working through Elliptic;
> see [near/far validation](2026-08-25-proximity-reports-near-and-far.md).

Date: 2026-08-24

Ten of the eleven sensors this firmware publishes work. Proximity is the one
exception, and this note records what it is not, so nobody repeats it.

## The control that matters

Light and proximity are two sub-sensors of one chip, on one driver, one I2C
port. Alternated, same envelope, same conditions:

```
ambient_light  on-change  2436 octets  768 x1, 1025 x22
proximity      on-change    32 octets  RIEN
proximity      on-change    32 octets  RIEN
ambient_light  on-change  2436 octets  768 x1, 1025 x22
```

Four rounds, identical every time. Proximity returns the QMI acknowledgement
and no indication — not a sample, not a configuration event, not an error, and
not an event under some other id: the raw bytes are thirty-two, every time.

That last point matters, because it is exactly how the SAR, `amd`, `rmd`,
`device_orient` and `tilt` looked until the decoder was fixed. They were
publishing under their own event ids. Proximity publishes nothing at all.

## The one attribute that differs

`iio-sensor-proxy` reads the published attributes, and out of seven fields only
one is not identical:

```
proximity      sample-rate: 0.000000 Hz
ambient_light  sample-rate: 5.000000 Hz
```

Same name, same vendor, same `on-change` stream type, both `available: yes`.

That looked decisive: a framework with no rate to configure would acknowledge
and drop, which is what happens. And `is_dri` turns out to control it — setting
`tcs3701.prox.config` `is_dri` to 0 makes proximity advertise 5 Hz, matching the
light sensor exactly.

**It changes nothing.** With a 5 Hz rate advertised, proximity still returns
thirty-two bytes and no indication. The rate was a symptom of the interrupt
configuration, not the gate. Restored to the stock value.

## Everything eliminated, each verified

Registry changes were read back from the served file afterwards to confirm they
took effect; earlier work in this repository was invalidated twice by edits the
parser silently regenerated.

| tried | result |
| --- | --- |
| `is_dri` 1 → 0, advertised rate confirmed to change | silent |
| `hw_id` 1 → 0, matching the working light sensor | silent |
| `res_idx`, subscription order, contention with another SEE client | silent |
| non-zero factory calibration offsets | overwritten by the driver 21 s into boot |
| `devinfo.ps` repointed from the absent `alsps` driver to `tcs3701` | silent |
| OnePlus display messages 0x10, 0x11, 0x12 sent to both sub-sensors | acknowledged, silent |
| screen genuinely off, `dpms DSI-1 = Off` | silent |
| request envelope, empty field 4 versus an empty payload field | identical |
| `soc_id` gate fixed so all twelve groups generate from config | silent, fix kept |

The served registry for proximity is byte-identical to what OxygenOS 10.0.13
wrote on this unit.

## What is known to work

- **The driver's proximity code runs.** It rewrites
  `tcs3701_platform.prox.fac_cal` with a zeroed result twenty-one seconds into
  every boot, which is what its own factory-calibration path stores on failure.
  That group is not regenerated from `sensors/config`, so the write is the SLPI's.
- **The chip sees an object.** Covering the sensor roughly triples the light
  sensor's raw channels on the same die, so the infrared emitter is driven and
  the reflection is measured.
- **The bus is fine.** The light sensor answers on it continuously.

## What is left

Reading what `sns_tcs3701` decides between accepting the request and emitting
nothing. Its messages for that region — `prox factory cal: offset calibration
failed`, `timeout, more than 100ms`, `first_prox data contaminated`,
`first_prox data saturated` — go to diag, and this port has no diag transport.

The alternative is finishing the disassembly of the sub-sensor dispatch in
`set_client_req`. Three attempts at that in this repository produced three
retractions, all from concluding on a partial branch, so it needs to be done
slowly or not at all.
