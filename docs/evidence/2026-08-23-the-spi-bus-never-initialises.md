# The SPI ULog's one message is a red herring

Date: 2026-08-23

**This document originally claimed the SPI NPA failure was the root cause.
That was wrong, and the correction is the useful part.** Keeping the whole
thing because the disproof is worth more than the claim.

## What the log says

The SLPI's entire `SPI` ULog is 16 bytes — one message, present in every
coredump on file including the earliest from 13 August:

```
== SPI @ 0x97855ff0 ==
+0x00000000 ts=197078030 spi_plat_init: npa_create_sync_client_ex failed
```

The strings beside it in the image name the resource:

```
0xb002cfb1 '/icb/arbiter'
0xb002cfbe 'SPI_QUP_DDR'
0xb002cfca 'spi_plat_init: npa_create_sync_client_ex failed'
```

so `spi_plat_init` asks the interconnect arbiter for a bandwidth-vote client
called `SPI_QUP_DDR`, and gets nothing back. Read as "the SPI transport is
never created", which is what I first concluded.

## Why that reading is wrong

The I2C driver makes the **identical** call. Same node, same client type,
only the name differs:

```
I2C @ 0xb00312c8   r0 = "/icb/arbiter"  r1 = "I2C_QUP_DDR"  r3:2 = (0x10, 0x400)
SPI @ 0xb0034d04   r0 = "/icb/arbiter"  r1 = "SPI_QUP_DDR"  r3:2 = (0x10, 0x400)
```

The difference is only that the SPI path checks the return and logs, while
the I2C path stores the handle without testing it. Both handles are in
memory, and both are null:

```
SPI handle  VA 0xb001b74c -> PA 0x97a5674c = 0x00000000
I2C handle  VA 0xb083a4f0 -> PA 0x97a3a4f0 = 0x00000000
```

I2C has no NPA client either — and I2C works completely: SX9324 probes over
it and streams live capacitance. So the client is a bandwidth optimisation,
not a prerequisite.

The control flow confirms it is non-fatal. On failure the code stores the
null handle, logs, and returns through the same epilogue as the success path:

```
b0034d1c: p0 = cmp.eq(r0,#0x0); if (!p0.new) jump 0xb0034cfc   ; success -> return
b0034d24: memw(##0xb001b74c) = r0                              ; failure -> store null
b0034d30: jump 0xb0034cf8                                      ; -> log -> return
```

There is no abort, no error propagation, no early exit. `spi_plat_init`
carries on.

The arbiter is not broken either, which is consistent: the `ICB Arb Log`
places votes 82 ms *before* the SPI message and continues afterwards, ramping
to 10 MB/s and then 3 GB/s before releasing. It services clients throughout.

## What the empty SPI log actually means

Nothing about initialisation. The neighbouring diagnostics in the same module
would all have fired had SPI got further and failed:

```
spi_plat_init: DAL_ClockDeviceAttach failed for clock id %d
spi_plat_init: DAL_TlmmDeviceAttach failed for tlmm id %d
spi_power_on : clock enable failed, handle 0x%x
spi_power_on : gpio enable failed, handle 0x%x
```

None of them appear. So the SPI transport is not reporting a failure — it is
reporting nothing, because **nobody ever asks it to do anything**. That is the
same shape as the ALS on I2C: the bus is fine, the driver never reaches it.

So the empty `SPI` ULog is a *symptom* of the accelerometer never
instantiating, not its cause. The open question is unchanged and is still the
one in
[the accelerometer note](2026-08-23-everything-waits-on-the-accelerometer.md):
why `sns_lsm6dsm` never creates its sensors.

## Method note

The `SPI` ULog resolves with the same trusted format-string relocation as
`I2C`, `0x185c5000`. The `ICB Arb Log` and `NPA Log` need a different one and
their format pointers remain unresolved, so the arbiter argument values quoted
above are raw and interpreted from the known master/slave numbering rather
than from a decoded format string.
