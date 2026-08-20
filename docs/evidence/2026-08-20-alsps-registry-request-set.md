# What the ALS driver actually asks the registry for

Date: 2026-08-20

The first reading of real driver code, made possible by two things: the
per-segment disassembly with unique addresses, and the discovery that segment
12 is the sensor PD's copy of segment 15 at a **constant offset of
0x2E4CC2A0**. That offset turns any string seen only in the PD's data into an
address the code can be searched for.

```
alsps_platform.config        seg12 0xe06f6fe8  ->  seg15 0xb222ad48
alsps_platform.cct.fac_cal   seg12 0xe06f7019  ->  seg15 0xb222ad79
```

## The request set

At `0xb21da96c` the ALS driver calls one helper, `0xb21da890`, seven times in a
row, once per registry group:

```
0xb222ad48  alsps_platform.config
0xb222ad5e  alsps_platform.als.fac_cal
0xb222ad79  alsps_platform.cct.fac_cal
0xb222ad94  alsps.als.config
0xb222ada5  alsps_platform.prox.fac_cal
0xb222adc1  alsps.prox.config
0xb222add3  stk2232_0_platform.ps.fac_cal
```

Six of the seven existed in the registry. **`alsps_platform.cct.fac_cal` did
not**, nor did its parent `alsps_platform.cct`, and the parent group
`alsps_platform` declared only `config`, `als` and `prox`. The phone's own
`persist` copy has the same hole, and so does the OxygenOS 11
`msmnile_alsps.json` from the LineageOS blobs.

`devinfo.rgb` in the phone's registry points straight at
`alsps_platform.cct.fac_cal`, so the part does have a colour-temperature
channel and the driver is right to ask.

## Closing the hole

`msmnile_alsps.json` now declares a `.cct` group with a `.fac_cal` of `scale`
and `bias`, modelled on `.als.fac_cal`, and the two registry entries plus the
amended parent were written directly so they took effect on the next boot.

It works, and the effect is measurable. Before, the file service showed eleven
`alsps*` groups being read and no `cct` at all. After:

```
3 alsps_platform.cct.fac_cal
3 alsps_platform.cct
... and the other ten, three times each
```

The driver's request set is now complete where before it was one group short.

## But it is not the blocker

No SUID for `ambient_light`, `proximity` or `rgb`, and a fresh coredump shows
the wire unchanged — 0x28 and 0x2c, the two SAR addresses, and nothing at
0x46. So the driver reads every group it asks for and still neither publishes
nor opens its port.

The change is kept: the group was genuinely missing, the driver genuinely wants
it, and `devinfo` says the channel exists.

## The lever for next time

The offset trick above is the useful part. Every driver's registry group names,
its attribute strings and its vendor string can now be located in
code-addressable memory, and from there the code that uses them. The comparison
to make is with the SAR, whose pool at `0xb222b970` carries `SX9324_SAR`,
`Semtech`, `sx9324_op_0_platform.config` — it is the one driver of the three
that reaches the wire, so what its init does after the registry callback is
what the ALS and the IMU are not doing.
