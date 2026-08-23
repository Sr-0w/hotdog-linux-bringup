# A device answers at 0x30 — the magnetometer is the MMC5603

Date: 2026-08-23

Using the one driver that probes cleanly as a bus scanner, and reading an
unwrapped trace, gives a hardware answer rather than an inference.

## The technique

`sns_ak0991x` is the only failing driver that instantiates, opens its bus and
reports a proper probe. Pointing it at a different `slave_config` turns it
into an address prober. Combined with removing the drivers whose chips are
absent — whose retry storms are what overwrite the 4 KB `I2C` ring — the
boot trace survives intact.

## The two probes, side by side

At its configured address `0x0c`:

```
setup lpi rsc 1 / open core 1 / open handle
   6 transfers to 0x0c
   3 x ERROR nack
close core 1 / reset lpi rsc 1
```

At `0x30`, everything else identical:

```
setup lpi rsc 1 / open core 1 / open handle
   2 transfers to 0x30
close core 1 / reset lpi rsc 1
```

with `I2C_error` **empty**. Both traces start at offset `+0x00000000`, so
nothing is lost.

Six transfers with three NACKs is a device that is not there, retried. Two
transfers with no error is a device that **answered**, whose identity register
then failed the driver's check — so it stopped without retrying.

## What that establishes

**There is a chip at address 0x30 on bus instance 1.** On a board whose config
offers exactly two magnetometer candidates — `ak0991x` at `0x0c` and
`mmc5603x` at `0x30` — the fitted part is the **MMC5603**, and the AK0991x
probe was always going to fail.

It also settles, on positive evidence, that **bus instance 1 works
electrically**: a device acknowledges on it.

## Which makes the magnetometer a one-driver problem

`sns_mmc5603x` is in the firmware (166 strings), its group
`mmc5603x_0_platform` is served with `slave_config` 48, and its chip is
present and answering. It simply never touches the bus — with `ak0991x`
removed so it was the only mag candidate, the `I2C` ULog was completely
empty.

So it fails the same way `sns_lsm6dsm` does, and for the magnetometer we now
know the hardware is fine. Whatever stops those two drivers from reaching the
bus is the entire remaining problem for two of the three missing families.

## Checked and eliminated on the way

- `rail_on_state` for both magnetometers had drifted to 2 where OxygenOS ran
  1 — the same drift found earlier on the LSM6DSM. Corrected to 1 and
  rebooted: no change. The value is kept because it matches what this unit
  ran.
- `mmc5603x_0_platform` is absent from the image as a literal, which suggested
  a name lookup failure. It is not: the image carries `mmc5603x_%d%s`, so the
  name is built at run time.
- Neither magnetometer requests a `vdd_rail` — only `vddio_rail`, with
  `num_rail` 1. That is what OxygenOS ran too, so it is by design, not drift.
