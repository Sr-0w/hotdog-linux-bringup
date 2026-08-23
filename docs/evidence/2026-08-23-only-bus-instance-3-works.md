# Only bus instance 3 works, and that gates registration

Date: 2026-08-23

Two results, one of which overturns something I asserted confidently earlier
in the day.

## The bus does gate registration

I had argued this was structurally impossible: a driver reads its
`<driver>_platform.config`, and therefore its `bus_type` and `bus_instance`,
from the registry during `init` — after the framework has created it — so the
bus could not decide whether it gets created. **That reasoning was wrong**,
and the experiment that refutes it is simple.

`sns_sx9324` is the one driver that demonstrably registers, probes and
streams. Moving it, by config file, off its native I2C instance 3:

| `sx9324_op_0_platform.config` | result |
| --- | --- |
| `bus_type=0`, instance 3 (native) | `sars` → `7335663959f5698867456bc70a6c70ca` |
| `bus_type=1`, instance 2 (SPI) | `sars` → **no SUID** |
| `bus_type=0`, instance 1 (I2C) | `sars` → **no SUID** |

The same driver, the same code path, the same everything else — only the bus
changed, and registration disappeared. Restored to instance 3 afterwards and
`sars` came straight back.

So bus reachability is consulted before the sensor is published, whatever the
ordering inside `init` looks like. Any driver placed on instance 1 or 2 fails
to register at all.

## Which explains most of the population

| driver | bus | registers |
| --- | --- | --- |
| `sns_sx9324` | I2C instance 3 | yes |
| `sns_alsps` | I2C instance 3 | yes (then blocks on `accel`) |
| `sns_lsm6dsm` | SPI instance 2 | no |
| `sns_ak0991x` | I2C instance 1 | no |
| `sns_mmc5603x` | I2C instance 1 | no |

Both magnetometers sit on instance 1 and the accelerometer on instance 2 —
exactly the two buses that kill registration. That accounts for every failing
driver's *primary* obstacle, and it is the first explanation in this
investigation that covers the whole population rather than one sensor.

## But the accelerometer has a second, separate blocker

Moving `lsm6dsm_0_platform` the other way — onto I2C instance 3, address 106,
the bus the SAR works on — does **not** bring it back:

```
sar bus: 3   lsm6dsm bus: 3 type 0
sars            7335663959f5698867456bc70a6c70ca
accel           no SUID
gyro            no SUID
```

So the bus is necessary but not sufficient for the LSM6DSM. Whatever else is
wrong with it survives being put on a working bus. The magnetometers have not
been tested this way yet — if either of them *does* come back on instance 3,
the accelerometer is alone in having a second fault, which would be worth
knowing.

## What this makes the next question

Not "why does `sns_lsm6dsm` not instantiate" in the abstract, but two
concrete ones:

1. **Why do bus instances 1 and 2 fail on this port while instance 3 works?**
   This is now the higher-value question: it blocks three of the five drivers,
   and it is a property of the platform rather than of any driver. Note the
   `SPI` ULog holds one benign message and the `I2C` ULog carries a populated
   transfer trace — but only instance 3 traffic appears there, so instance 1
   is as silent as SPI despite being I2C.
2. What the accelerometer's second fault is, once its bus is no longer in the
   way.

## Method note, and a retraction

The claim in
[the driver inventory note](2026-08-23-which-drivers-this-firmware-actually-contains.md)
that "the bus cannot gate instantiation for a structural reason" is retracted.
It was reasoning from an assumed ordering rather than from a measurement, and
the measurement says otherwise. The earlier LSM6DSM-on-instance-3 test was
read as confirming that reasoning; it does not — it shows a second fault,
which is a different and more useful thing.
