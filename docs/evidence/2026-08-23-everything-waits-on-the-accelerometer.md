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

sixteen bytes is a header, not traffic. The SLPI's SPI path never carries
anything, while its I2C path demonstrably works end to end.

Tested and eliminated as causes of the accelerometer's absence, each by
measurement: candidate collision (reduced by config file to `lsm6dsm_0` as
the only hardware sensor, 35 registry groups regenerated, still no SUID), the
board identity (`oppo_project` now correctly 19801), and the config gate
(`msmnile_lsm6dsm.json` accepts `MTP` and soc 339).

## Next

Why the SLPI's SPI bus instance 2 is silent. That is now the whole problem —
not the ALS, not the registry, not the QDI boundary, all of which are proven
working by a sensor that streams.
