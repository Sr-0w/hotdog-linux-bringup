# Everything waits on the accelerometer

Date: 2026-08-23

The problem is not "the sensors do not register". Most of them *are*
registered, with live sensor objects and SUIDs in the sensor PD. They are
blocked waiting on a dependency that never arrives, and that dependency is
`accel`.

## The sensor objects exist

The ALS driver's `init` at `0xb21d9af0` writes a hardcoded SUID byte by byte
before publishing anything:

```
b21d9b28: memb(r4+#0x1) = #0x61      ...      b21d9b60: memb(r4+#0xf) = #0x5f
b21d9b68: memb(r29+#0x0) = #0x62
```

which assembles `62614354524c22353931912c435d525f`. Searching the sensor PD
in a live coredump for that byte string finds it — the ALS sensor object is
real. Its neighbour at `0x9869da81` differs only in the first byte and three
digits (`caCTRL"681`), which is the proximity or CCT sibling.

They sit in a repeating structure at stride `0x330`, each holding a
dependency list:

```
0x9869d3a1  registry  interrupt  timer  resampler     <- ALS
0x9869d711  registry  interrupt  timer  resampler
0x9869da81  registry  interrupt  timer  resampler
0x9869fdbc  registry  interrupt  timer  sars          <- SAR, complete
```

## What each driver asks for

`0xb21dbe08` runs between the SUID assignment and the attribute publication,
and issues one `0xb21dada8` call per dependency with a name and a length:

| driver | dependencies requested |
| --- | --- |
| ALS (`sns_alsps`) | `interrupt`, `timer`, **`accel`**, `resampler`, `registry` |
| SAR (`sns_sx9324`) | `timer`, `interrupt`, `registry` |

Cross-checked against the live census: `interrupt`, `timer`, `resampler` and
`registry` all publish SUIDs. **`accel` does not.**

So the SAR's dependency set is fully satisfiable and it completes — it
publishes its type, answers the lookup, and streams real samples. The ALS
asks for one more thing than the SAR does, that one thing never resolves, and
it never reaches the attribute publication at `0xb21d9b84`. Which is exactly
why the resolved dependency list in memory shows four entries and not five:
`accel` was requested and never came back.

## Counted in memory

Dependency slots in the sensor PD are laid out as `{const char *name;
uint32 len; sns_sensor_uid suid;}`. Scanning the live band
`0x98690000`–`0x986a4000` for slots whose name pointer is one of the known
dependency strings, and checking whether the SUID that follows has been
filled in:

| dependency | slots | still null |
| --- | ---: | ---: |
| `registry` | 19 | 0 |
| `timer` | 9 | 0 |
| `interrupt` | 1 | 0 |
| `resampler` | 16 | 0 |
| **`accel`** | **12** | **9** |

Every other dependency resolves in every slot it appears in. `accel` is asked
for twelve times and nine of those are still waiting. That is nine sensor
objects sitting blocked on an accelerometer that never arrives — the finding
above, counted rather than inferred.

That also settles an earlier wrong conclusion of mine. I had reasoned that
because the publication function has no guard, "if init ran, `ambient_light`
would have a SUID, therefore init never runs". Init does run. It runs, sets
the SUID, requests dependencies, and then waits.

## What this reframes

Every hardware sensor except the SAR is downstream of the accelerometer:

- ALS, proximity and CCT block on `accel` explicitly;
- `gyro` shares the LSM6DSM driver with `accel`;
- the fusion and motion sensors (`gravity`, `game_rv`, `rotv`, `fmv`, `amd`,
  `rmd`, `smd`, `tilt`, `device_orient`, `step_*`, `md`) are all accel-derived
  by construction;
- `mag_cal`, `geomag_rv` need accel too.

So this is not a broad "SSC does not work on mainline" problem with many
independent causes. It is **one** missing sensor with a long dependency tail,
plus one sensor (the SAR) that happens to sit outside that tail and works
perfectly.

## Where the accelerometer fails

`lsm6dsm_0_platform.config` puts it on **bus instance 2 with `slave_config`
0** — SPI, not I2C. The working SAR is on I2C bus instance 3. And the `SPI`
ULog in every capture is empty:

```
0x97851760 I2C        write=56    (plus a populated transfer trace)
0x97853ac0 SPI        write=16
0x978543c0 SPI_error  write=0
```

sixteen bytes is one message. **It does not mean the bus failed to come up** —
see [the retraction](2026-08-23-the-spi-bus-never-initialises.md): that message
is a non-fatal NPA diagnostic that the I2C driver also triggers and simply does
not check. The empty SPI log means nothing ever asked the bus to do anything,
which is a symptom of the accelerometer not instantiating rather than a cause.

Tested and eliminated as causes of the accelerometer's absence, each by
measurement: candidate collision (reduced by config file to `lsm6dsm_0` as
the only hardware sensor, 35 registry groups regenerated, still no SUID), the
board identity (`oppo_project` now correctly 19801), and the config gate
(`msmnile_lsm6dsm.json` accepts `MTP` and soc 339).

## Two different failure modes

Scanning the driver code for runs of `memb(rX+#n) = #imm` recovers each
driver's hardcoded SUID. The method validates on the SAR: it yields
`ca706c0ac76b45678869f55939663573`, which is the `sars` SUID the live census
reports. Applied to the others:

| driver | hardcoded SUID (byte 0 stored separately) | present in the runtime sensor list |
| --- | --- | --- |
| ALS | `…614354524c22353931912c435d525f` | yes — `0x97f51f61`, `0x9869d392` |
| SAR | `…706c0ac76b45678869f55939663573` | yes — `0x97f57d01`, `0x9869fded` |
| LSM6DSM | `…4b1a6d68da4a7785ab46e2cda5680b` | **no** |
| LSM6DSM | `…32b89cdc0240afa38f80c0c0153697` | **no** |

The two LSM6DSM matches land at `0x982e706d` / `0x9868e06d` and
`0x982e7095` / `0x9868e095` — pairs separated by exactly `0x3A7000`, which is
the root-PD/sensor-PD offset for the static data segments, and below the
`0x98696000`–`0x986a3000` band where every live sensor object and dependency
list sits. They are static image copies, not instantiated sensors.

So the two failures are not the same:

- the **ALS** creates its sensors, assigns their SUIDs, requests dependencies
  and blocks on `accel`;
- the **accelerometer** never creates its sensors at all.

## Next

Why `sns_lsm6dsm` never instantiates. Its attribute publication is at
`0xb21c7d1c` and its driver body spans roughly `0xb21c0000`–`0xb21cf000`.
It is the only remaining root: the ALS chain, the registry, the QDI boundary
and I2C are all proven working by a sensor that streams.

### Its config had drifted from the one that worked on this phone

The phone still carries the registry OxygenOS 10.0.13 wrote on this exact
unit, at `/root/registry-backup-oos10`. Diffing our served platform configs
against it:

| group | difference |
| --- | --- |
| `sx9324_op_0_platform.config` (works) | none |
| `alsps_platform.config` | none |
| `lsm6dsm_0_platform.config` | `irq_pull_type` 3 vs **2**, `num_rail` 2 vs **1**, `rail_on_state` 2 vs **1** |

The only config that had drifted was the one sensor at the root of the
failure — our set comes from OxygenOS 11 blobs, the backup from the build
that actually ran here. Aligned to the stock values in
`msmnile_lsm6dsm.json` and rebooted; the regenerated registry confirms
`num_rail=1`, and the accelerometer still does not register. So this is not
the cause either, but the stock values are kept: they are the ones this
hardware is known to have worked with, and the divergence was real.

Its bus is the one thing structurally different from the working control —
`bus_type=1` (SPI) instance 2, against `bus_type=0` (I2C) instance 3 for the
SAR — and the `SPI` ULog holds 16 bytes against a populated I2C transfer
trace. The stock OxygenOS registry confirms the LSM6DSM is the part actually
fitted: its groups alone carry the factory-written `accel.nom_val`,
`gyro.nom_val`, `ff` and `hs` entries that the other IMU candidates lack.

## A data-loss trap, recorded

Deleting files from `sensors/registry/` to force a clean regeneration
destroys per-unit factory calibration. The parser recreates the groups from
the config JSON, which carries defaults:

```
after deletion   "x":{"type":"flt","ver":"0","data":"0.000000"}
from backup      "x":{"type":"flt","ver":"1","data":"-0.086188"}
```

Both the accelerometer and gyroscope bias groups were zeroed this way and
restored from `/root/reg-full-backup`, verified to survive a reboot. The
`ver:1` marker is what distinguishes measured calibration from a default.
Remove a **config JSON** to drop a candidate; never a registry group.
