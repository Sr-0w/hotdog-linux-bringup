# The proximity driver runs, calibrates, and stores a failed result

Date: 2026-08-23

The strongest evidence yet about where proximity stops, obtained by trying to
override its factory calibration and watching what happened to the override.

## The driver rewrites its own calibration at every boot

`tcs3701_platform.prox.fac_cal` ships with `offset1` and `offset2` at zero. The
driver's own message strings describe an offset calibration that can fail:

```
sns_tcs3701_hal_island.c:prox factory cal: offset calibration failed, setting: 1
sns_tcs3701_hal_island.c:prox factory cal: timeout, more than 100ms
sns_tcs3701_hal_island.c:prox factory cal: offset_l: %d, offset_h: %d, config: %d
sns_tcs3701_hal_island.c:prox factory cal : prox fac calib finished
```

so the obvious test is to supply non-zero offsets and see whether that skips the
calibration. Both were set to 20.0 and the phone rebooted. After boot:

```
offset1=0.000000  offset2=0.000000
fichier modifie   19:37:11
demarrage         19:36:50
```

**The file was rewritten 21 seconds after boot.** That group is not regenerated
from `sensors/config` — no config JSON mentions `fac_cal` — so this is the SLPI
writing back through `hexagonrpcd`, which serves the registry read-write.

Three things follow, none of them previously established:

1. `sns_tcs3701`'s proximity code **runs**. It is not skipped, not gated off,
   not waiting on a dependency. It reaches its factory-calibration step.
2. That step **completes and stores a result**, and the result is zero — which
   is what a failed offset calibration would write.
3. **Overriding the registry cannot work.** Any value put there is replaced
   during init, which retires that whole line of experiment.

## What it points at

The calibration reads `prox_info.raw` from the chip and gives up after 100 ms.
For it to time out, the chip must not be producing a proximity reading — while
the ALS on the same die, the same I2C port and the same rails answers normally.

That splits into two candidates, and they are distinguishable by one physical
gesture rather than by more configuration:

- **the chip sees nothing** — the infrared emitter is not driven, so no object
  is ever detected. The `canaux` check in
  [the guided test](../../helpers/hotdog-sensor-check.py) settles it: if no ALS
  channel moves when a finger covers the sensor, the optical path itself is
  dark.
- **the chip sees, but cannot signal** — proximity is interrupt-driven on
  GPIO 117 (`is_dri 1`), and both its data path and its calibration wait on
  that interrupt. If sensor GPIO interrupts are not delivered to the SLPI at
  all, proximity fails and nothing else visibly does: the ALS is timer-driven
  (`is_dri 0`), and the accelerometer and gyroscope stream at a requested rate.

## The SAR is the witness for the second candidate

`sns_sx9324` is the only on-change sensor whose input can be changed by hand.
Its earlier "responds when polled" result proves nothing: an on-change sensor
publishes its current value the moment a client subscribes, with no interrupt
involved. The test was therefore hardened to require a **change after the
initial value**, which only happens if the chip asserted its line and the SLPI
received it.

If the SAR never changes either, then no sensor interrupt reaches the SLPI on
this port, and that explains proximity without invoking anything specific to its
chip. If the SAR does change, interrupts work and the fault is in the optical
path or in the driver's proximity handling alone.

Both checks need one gesture each and cannot be answered from the workstation.
