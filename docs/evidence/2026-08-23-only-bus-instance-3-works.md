# A driver deregisters when its chip does not answer

Date: 2026-08-23

**The title of this note was "Only bus instance 3 works, and that gates
registration". That conclusion was wrong and is retracted below.** The
measurements are sound; the reading of them was not.

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

## RETRACTED: the bus is not what fails

A coredump taken *while* the SAR sat on instance 1 shows the resolved I2C log:

```
ts=412075478  cancel 0xb0028f5c
ts=412075518  OFF 0xb0028f5c
ts=412075853  close core 1
ts=412078870  close handle 0xb0028f5c
ts=412079055  reset lpi rsc 1
```

That is an **orderly teardown**, not a failed open: core 1 was opened, used,
and released, with `I2C_error` carrying `ERROR nack` shortly before. The
message strings resolve only without a relocation — they live in the root-PD
pool around `0xb0315100`, while sensor-PD messages need `0x185c5000`, which
is why the tool left them as raw pointers.

So the simple explanation holds: **the SX9324 is not present on instance 1**,
it did not answer, and the driver deregistered itself. Moving a driver to a
bus where its chip is absent makes it deregister — which says nothing about
whether that bus works.

The genuinely useful thing this establishes is the mechanism: **a SEE driver
that cannot reach its chip removes its own sensors**, so absence of a SUID is
consistent with a failed probe and not only with a failed registration. That
reframes the LSM6DSM: on I2C instance 3 at address 106 there is no LSM6DSM to
answer, so deregistering there is expected and proves nothing either.

## What the table below actually shows

| driver | bus | registers |
| --- | --- | --- |
| `sns_sx9324` | I2C instance 3 | yes |
| `sns_alsps` | I2C instance 3 | yes (then blocks on `accel`) |
| `sns_lsm6dsm` | SPI instance 2 | no |
| `sns_ak0991x` | I2C instance 1 | no |
| `sns_mmc5603x` | I2C instance 1 | no |

The correlation with bus instance is real but is not causal on its own: it
reflects which chips are where. What still needs explaining is why the
accelerometer, on its **own** bus with its **own** chip present, produces no
SPI traffic at all — the `SPI` ULog holds one benign NPA message and nothing
else, while I2C instance 3 carries a populated transfer trace.

## The accelerometer on a foreign bus

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

## Bus instance 1 is proven functional, which closes the bus question

Counting bus-core open/close events across two captures, with the root-PD
strings resolved:

| capture | cores touched |
| --- | --- |
| stock config | `close core 3` ×2 — **core 1 never opened** |
| SAR forced onto instance 1 | `close core 1` ×1 **and** `close core 3` ×1 |

The second row is the useful one: when a driver actually asks for instance 1,
the SLPI opens it, uses it and releases it. **Instance 1 works.** It is simply
never requested in the stock configuration.

Both magnetometer drivers — `sns_ak0991x` and `sns_mmc5603x` — are configured
on instance 1 and neither ever opens it. The accelerometer is on SPI instance
2 and never calls `spi_open` either; the SPI module would have logged
`spi_open : invalid execution level, instance %d` had it tried and failed, and
its ULog holds only the one inert NPA line.

So the three failing drivers never reach the bus at all, on any bus, working
or not. The bus is definitively not the cause, this time on positive evidence
rather than on an ordering argument.

For completeness, the NPA handles both drivers fail to create are never read
back: `0xb001b74c` (SPI) and `0xb083a4f0` (I2C) each appear exactly once in
the whole image, as the store that writes them. Nothing dereferences either.
The earlier retraction of the NPA root-cause claim is confirmed by this too.

## Where that leaves it

`sns_lsm6dsm`, `sns_ak0991x` and `sns_mmc5603x` do not instantiate, and
nothing about the bus, the transport, the NPA client, the registry, the board
identity or the config explains it. `sns_alsps` and `sns_sx9324` do, from the
same image, through the same framework.

## Caveat: the I2C ULog is a ring buffer and it always wrapped

The claim above that "both magnetometer drivers never open instance 1" rests
on `close core 1` being absent from the stock captures. That absence is
**not** established, because the `I2C` ULog is circular and had already
wrapped in every capture taken, including one deliberately triggered ~20 s
after the SLPI came up:

```
entrees I2C: 105    premier offset: +0x00001cc4
```

The buffer starts mid-way, so boot-time probing is overwritten by the time
any coredump can be taken. Attempting to read the per-core context array
instead does not help: the contexts at `0xb0028f20 + n*0x3c` are all zero in
the dump, because ports are closed and released after probing — consistent
with the two `close core 3` / `close handle` pairs for the SX9324 at `0x28`
and the SX932x at `0x2c`, and with the SAR reopening its port only when a
client subscribes.

What survives unaffected:

- **instance 1 works** — forcing the SAR onto it produced `close core 1`,
  `close handle`, `reset lpi rsc 1`. That is positive evidence and does not
  depend on the ring buffer.
- the accelerometer never calls `spi_open`, since the SPI ULog is *not*
  wrapped (16 bytes used of 2048) and contains only the inert NPA line.

What is now open again: whether the magnetometers probe instance 1 and
deregister, or never touch it. Settling it needs the log captured before it
wraps — which means either a much earlier crash trigger than the SLPI's own
boot allows, or reading the buffer through a path that does not require
crashing the subsystem.
