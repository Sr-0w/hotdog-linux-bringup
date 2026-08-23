# The SPI bus never initialises, and that is the root cause

Date: 2026-08-23

One line of firmware log closes the whole chain:

```
== SPI @ 0x97855ff0 ==
+0x00000000 ts=197078030 spi_plat_init: npa_create_sync_client_ex failed
```

That is the entire contents of the SLPI's `SPI` ULog — 16 bytes, one message,
in every coredump on file including the earliest from 13 August.

## What it means

The strings immediately preceding it in the image name the resource being
requested:

```
0xb002cfb1 '/icb/arbiter'
0xb002cfbe 'SPI_QUP_DDR'
0xb002cfca 'spi_plat_init: npa_create_sync_client_ex failed'
```

`spi_plat_init` creates an NPA (Node Power Architecture) synchronous client
against `/icb/arbiter` named `SPI_QUP_DDR` — the interconnect bandwidth vote
for the SPI QUP's path to DDR. The client creation fails, `spi_plat_init`
aborts, and the SLPI's SPI transport is never brought up.

## The chain, end to end

```
npa_create_sync_client_ex("/icb/arbiter", "SPI_QUP_DDR") fails
  -> spi_plat_init aborts, SPI transport absent
  -> sns_lsm6dsm (bus_type=1 SPI, instance 2) cannot probe
  -> accel and gyro never instantiate, no SUID
  -> sns_alsps blocks on its accel dependency, never publishes a data type
  -> ambient_light, proximity, cct, rgb never answer a lookup
  -> every fusion and motion sensor, all accel-derived, never appears
```

and the one sensor that works is the one outside the chain: `sns_sx9324` on
**I2C** instance 3, whose dependency list is `timer`, `interrupt`, `registry`
and nothing else. It probes, publishes, and streams real capacitance.

This is why every configuration experiment produced the same result. Config
set, registry contents, candidate collision, gating, rails, `placement`,
`devinfo`, board identity — none of them could matter, because the transport
the accelerometer needs was never created.

## The arbiter itself is not broken

Worth being precise, because an earlier note in this repo blamed the ICB
arbiter and was superseded. The `ICB Arb Log` shows it working on both sides
of the failure:

```
ts=196995980  master 0x83 slave 0x8f  val 0x00000001
ts=196996025  master 0x70 slave 0x19  val 0x00000001
ts=196996045  master 0x34 slave 0x2f  val 0x00000001
ts=197078030  <- spi_plat_init fails here
ts=197110606  master 0x83 slave 0x8f  val 0x00989680   (10 MB/s)
ts=197251884  master 0x83 slave 0x8f  val 0xb2d05e00   (3 GB/s)
ts=197417391  master 0x83 slave 0x8f  val 0x00000000   (released)
```

Votes are placed and released normally. So the arbiter services clients; it
is the creation of this particular client that fails. Note that master `0x34`
appears only in the first batch and never again, while `0x4c` and `0xb4` join
later — the master set changes across the failure point.

## What is not yet known

Why `npa_create_sync_client_ex` returns failure. Candidates, in the order
worth checking:

- the NPA node `/icb/arbiter` exists but the named resource `SPI_QUP_DDR` is
  not defined on it, so the lookup fails;
- the node exists but client creation is refused because a dependency of that
  node has not been created yet — NPA is ordered, and `spi_plat_init` runs at
  `ts=197078030`, *before* the 10 MB/s votes at `197110606`, so it may simply
  be running too early;
- a client limit, cf. the neighbouring string
  `SPI: Exceeding max supported clients per pd`.

The timing detail is the most suggestive: the SPI init happens between the
arbiter's first trivial votes and its first real bandwidth votes, which is
consistent with the interconnect not being fully up when SPI asks for its
client.

Neighbouring diagnostics in the same module, none of which appear in the log
and all of which would if initialisation had got further:

```
spi_plat_init: DAL_ClockDeviceAttach failed for clock id %d
spi_plat_init: DAL_TlmmDeviceAttach failed for tlmm id %d
spi_power_on : clock enable failed, handle 0x%x
spi_power_on : gpio enable failed, handle 0x%x
```

So the failure is strictly at the NPA client step — before clocks, before
TLMM, before any pin is touched. Nothing about pinctrl, GPIO ownership or
the SPI wiring is implicated.

## Method note

The `SPI` ULog resolves with the same trusted format-string relocation as
`I2C`, `0x185c5000`. The `ICB Arb Log` and `NPA Log` need a different one and
their format pointers are still unresolved; the argument values above are
raw and their meaning is inferred from the arbiter's known master/slave
numbering, not from a decoded format string.
