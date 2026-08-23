# The magnetometer probes and is NACKed — a complete unwrapped trace

Date: 2026-08-23

First fully readable boot-time I2C trace of this investigation, and the first
definite hardware answer.

## Making the log readable

Every previous capture found the `I2C` ULog already wrapped — even one
triggered ~20 s after the SLPI booted started at `+0x1cc4`. The cause is
`sns_sx932x`, configured at address `0x2c` where no chip exists: it retries,
NACKs, and fills the 4 KB ring before any coredump can be taken.

Moving `msmnile_sx932x_op.json` and `msmnile_sx932x.json` aside — the SX932x
is not the fitted part, the SX9324 at `0x28` is — immediately changed the
picture. Removing `msmnile_sx9324_op.json` as well left the bus quiet enough
that the log starts at offset **`+0x00000000`**: nothing lost.

That is the reusable technique: **to read a boot trace, first remove the
drivers whose chips are absent**, because their retry storms are what
overwrite it.

## What the magnetometer actually does

```
setup lpi rsc 1
open core 1
open handle 0xb0028f20
   6 transfers to address 0x0c (12)
   3 × ERROR nack
close core 1
close handle 0xb0028f20
reset lpi rsc 1
```

`sns_ak0991x` instantiates, opens bus instance 1, addresses `0x0c` three
times, is NACKed every time, and removes itself. **There is no AK0991x at
address 0x0c on bus instance 1.**

This also settles the question left open by the ring-buffer caveat: the
magnetometer driver does reach the bus. Its failure is a probe failure, not a
registration failure — the same mechanism the SAR showed when moved off its
chip.

## And the other magnetometer never tries

With `ak0991x` removed so `mmc5603x` was the only mag candidate, the `I2C`
ULog is empty — 4 entries, no messages, no addresses. `sns_mmc5603x` never
touches the bus at all, exactly like `sns_lsm6dsm`.

So the five drivers split three ways, not two:

| driver | behaviour |
| --- | --- |
| `sns_sx9324` | probes `0x28`, answers, streams |
| `sns_ak0991x` | probes `0x0c`, **NACK**, deregisters |
| `sns_alsps` | instantiates, blocks on the `accel` dependency before probing |
| `sns_lsm6dsm` | never reaches the bus |
| `sns_mmc5603x` | never reaches the bus |

## A dead end checked on the way

`mmc5603x_0_platform` is absent from the image as a literal, which suggested
the driver looks up a name that does not exist. It does not: the image
contains `mmc5603x_%d%s`, so the group name is built at run time and would
resolve to `mmc5603x_0_platform`, which the registry serves. Not the cause.

## What is now worth knowing

Whether `0x0c` is the right address for this board's magnetometer at all.
OxygenOS ran the same `ak0991x_0_platform.config` with `slave_config` 12, so
either the part answers there under OxygenOS and not here — which would point
at power or bus timing rather than at the address — or the fitted part is the
MMC5603 at `0x30` and the AK0991x probe is expected to fail, in which case
the real question is why `sns_mmc5603x` never probes.

The stock OxygenOS registry offers a hint: it contains no `devinfo.mag`
entry, while it does carry `devinfo.als`, `.gsensor`, `.gyro`, `.ps` and
`.rgb`. Whichever magnetometer ran there did not register a calibration path.
