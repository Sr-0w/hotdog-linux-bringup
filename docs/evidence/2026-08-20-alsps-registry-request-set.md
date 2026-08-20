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

## The dispatcher and the handler, mapped

Both drivers have the same two-phase shape, and both phases are now located.

**Request**, ALS at `0xb21da96c`: seven consecutive calls to `0xb21da890`, one
per group name, adding each to the request set.

**Dispatch**, ALS at `0xb21db1a0`, SAR at `0xb21e2814`: a chain of calls to the
shared name-compare helper `0xb216ede0`, one per known group, each followed by
`p0 = cmp.eq(r0,#0)` and a branch to that group's handler. The SAR's chain
matches `sx9324_op_0_platform.config` at `0xb21e2848`; the ALS's matches
`alsps_platform.config` at `0xb21db1cc` and `alsps_platform.cct.fac_cal` at
`0xb21db23c`. The two are structurally identical, so the ALS is not failing for
want of a dispatcher.

**Handler**, ALS `alsps_platform.config` at `0xb21db4c8`:

```
b21db524: call 0xb2071aa8            ; protobuf decode, descriptor 0xb2044300
b21db534: p0 = r0
b21db53c: if (!p0.new) jump 0xb21db340   ; decode failed -> abandon this group
b21db544: r3 = memw(r18+#0xf4)       ; and on success, copy the decoded fields
b21db54c: r2 = memub(r18+#0x107)     ; into driver state at +0x68, +0x64, +0x70…
```

So a group whose payload does not decode is dropped **silently** — no log, no
diag message. That matches the symptom exactly: the driver reads every file,
never complains, and never proceeds.

Whether the decode actually fails, and for which group, is the next thing to
settle. The state offsets are known (`+0x64`, `+0x68`, `+0x6c`, `+0x70`,
`+0x74`, `+0x78`, `+0x80` receive the platform fields), so a coredump taken
while the sensor PD is alive can be read to see which of them were ever
populated — that distinguishes "decode failed" from "decode fine, blocked
later" without any further disassembly.
