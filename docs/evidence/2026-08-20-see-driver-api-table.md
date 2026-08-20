# The SEE driver API table, and where to pick the comparison up

Date: 2026-08-20

Built on the per-segment disassembly from
[`scripts/slpi/slpi-disassemble.sh`](../../scripts/slpi/slpi-disassemble.sh),
which is the first version of that output whose addresses are unique.

## The table

SEE registers each driver through two structures — `sns_sensor_api`, whose
`struct_len` is 20, and `sns_sensor_instance_api`, whose `struct_len` is 24.
Scanning the non-executable segments for a small length field followed by four
or five pointers that land inside an executable segment finds them: **54
entries**, laid out consecutively in segment 12 from `0xe06b3ab8`, alternating
20-byte and 24-byte forms.

```
api20  @0xe06b3ab8  0xb21b073c 0xb21b0824 0xb21b0838 0xb2072c0c
api20  @0xe06b3d68  0xb21b250c 0xb21b2978 0xb21b2a50 0xb2073574
api24  @0xe06b3d94  0xb21b3e30 0xb21b4000 0xb20762d8 0xb21b4150 0xb21b4040
...
api24  @0xe06b57b0  0xb21dc820 0xb21dca80 0xb209a788 0xb21dcaa8 0xb209a504
```

For the 20-byte form the pointers are `init`, `deinit`, `get_sensor_uid`,
`set_client_request`. That is the entry point for every driver in the image,
including the three that matter.

## What did not work to name them

**Proximity of addresses.** `0xb21c7128` sits close to the LSM6DSM attribute
block and looked like its `init`; disassembling it and resolving the strings it
logs gives `timer`, `interrupt`, `async_com_port` — a different driver
entirely. Guessing by address is not identification.

**Following the call graph upward.** The attribute-publication block at
`0xb21c7b80` has no direct caller anywhere in the executable segments, so it is
reached through a pointer. The same is true of `0xb21c6ebc`. Naming an entry
therefore has to come from the data each `init` touches, not from who calls it.

**The full registry group names.** `lsm6dsm_0_platform.config` and
`alsps_platform.config` exist only in segment 12, and no code references those
addresses. The short names do appear in a code-addressable segment —
`lsm6dsm` at `0xb2229390`, referenced once at `0xb21c7ca4`; `alsps` at
`0xb222ac73`, referenced once at `0xb21d9bb8` — which suggests the drivers
build their group names at run time from the short name, and that the seg12
strings are the assembled results.

## Where to resume

Two anchors are solid and were confirmed against the clean disassembly:

```
lsm6dsm   short name 0xb2229390, used at 0xb21c7ca4
alsps     short name 0xb222ac73, used at 0xb21d9bb8
```

Both sit inside attribute-publication loops, so both drivers' `init` does run.
The next step is to match those two code regions to their entries in the table
above — by disassembling each of the 54 `init` functions and looking for the
one whose body reaches `0xb21c7ca4` and the one that reaches `0xb21d9bb8` —
and then to do the same for the SAR, whose strings are
`sns_sx9324_sensor_island.c:…` in segment 16. With the three entries named, the
comparison is direct: the SAR reaches the I2C wire and the other two never do,
so whatever the SAR's `init` does after publishing attributes is what the other
two are not doing.
