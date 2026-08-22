# Where `als_type` comes from, and four things it is not

Date: 2026-08-23

Continuing the sensor-level hunt: the ALS publishes no SUID, and
`Unsupported sensor %d` was the message to chase. This resolves where that
message is emitted, traces `als_type` to its source, and closes four
candidate explanations.

## A correction that moves two messages

The diag descriptor layout is `(file/line, flags, msg_ptr)` — the pointer
comes **after** its file/line word, not before. The earlier reading had the
triples off by one slot, which mis-assigned two messages in
`sns_alsps_sensor.c`:

| descriptor | line | message | args |
| --- | ---: | --- | ---: |
| `0xb222b01c` | 1014 | `Unsupported sensor %d` | 1 |
| `0xb222b028` | 1076 | `als_type %d ps_type %d is_unit_device %d is_als_dri…` | 4 |

The argument counts settle it: the call site at `0xb21dbdf4` passes four
arguments, so it is the `als_type…` line, not `Unsupported sensor`. The
previous note had these swapped.

## `Unsupported sensor` is a registry group-name builder

The real site is `0xb21dbc78`, inside the function at `0xb21dbaf0`. That
function assembles group-name strings on the stack from immediates —
`0x70736c61` "alsp", `0x6c705f73` "s_pl", `0x6f667461` "atfo", then one of
`0x612e6d72` "rm.a", `0x632e6d72` "rm.c", `0x702e6d72` "rm.p" — producing
`alsps_platform.als`, `alsps_platform.cct` and `alsps_platform.prox`.

The selector accepts exactly three values of its type argument `r17`:

```
b21dbb48: p0 = cmp.eq(r17,#0x1)
b21dbb8c: p0 = cmp.eq(r17,#0x4); if (p0.new) jump:t 0xb21dbba0
b21dbb94: p0 = cmp.eq(r17,#0x2); if (!p0.new) jump:t 0xb21dbc68   ; -> Unsupported
```

Anything outside `{1, 2, 4}` falls to `0xb21dbc68` and logs the message with
`r17`.

**This is not the failure.** All three groups are served, and the DSP
requests them — the `cct` group is requested eight times per boot. The
builder is doing its job.

## `als_type` resolves to a platform table

`als_type` lives at driver `state+0x27c` and reaches it through
`0xb21dbd78`:

```
b21dbd90: r1:0 = combine(#-0x1,#0x3)     ; index 3, mask -1
b21dbda8: call 0xb21b01fc                ; lookup -> r29+0x10
b21dbdb0: r4 = memw(r29+#0x10)
b21dbdb4: if (cmp.eq(r4.new,#0x0)) jump:nt 0xb21dbdd4   ; NULL -> copy skipped
b21dbdb8: r2 = memw(r4+#0x8c)
b21dbdbc: memw(r17+#0x274) = r2.new      ; == state+0x27c, als_type
```

The lookup (`0xb21b01fc` wrapping `0xb21b0154`) walks a table of at most 11
entries of `0x174` bytes each; entry *i* validates itself with `entry[+4] ==
i`, and a mask argument of `-1` short-circuits to `entry+8`. The wrapper
returns `found+4`, so `als_type` is `table + 3*0x174 + 0x98`.

If the lookup fails, the copy at `b21dbdb8` is skipped and `als_type` keeps
its previous value — zero. Zero is not in `{1, 2, 4}`, which is what made
this look like the whole story.

## But the table is populated

The table pointer is `0xb28d8f14`, gated by a handle at `0xb22b0534` that
`0xb2114de8` fills from a QDI call. Both were read out of every SLPI
coredump on file — 25 of them, across every configuration tried:

```
handle   0xb22b0534 = 0x00001030
table    0xb28d8f14 = 0xe65f2648
```

Non-zero in all of them, and identical. (The one exception,
`01-slpi-oos10-stalled-init.elf`, reads `0xd0d0d0d0` / `0x00000000` — that is
the OOS10 stalled-init capture, poisoned memory from a subsystem that never
finished booting.)

So the platform table is built and reachable. "The table is missing" is
eliminated. The remaining question — whether *entry 3* specifically is
valid — could not be answered from the dumps: `0xe65f2648` is runtime heap
with a scattered page mapping, and a signature scan for a self-indexing run
at stride `0x174` found no candidate in the captured physical range.

## Reading SLPI virtual addresses in a coredump

Recorded because it cost time and is reusable. Coredump program headers carry
**physical** addresses; the disassembly is **virtual**. Pairing the firmware
and coredump segments by size gives two constant deltas:

| firmware segments | virtual base | mapping |
| --- | --- | --- |
| 14–17 | `0xb2100000` | `PA = VA - 0x1A600000` |
| 18–21 | `0xb2000000` | `PA = VA + 0x162D9000` |

The `0xe65xxxxx` and `0xe06xxxxx` regions are *not* linearly mapped — seg8
and segs 9–11 need different deltas — so anything in that range has to be
found by content, not arithmetic.

## Eliminated this pass

**The missing `placement` group.** `sx9324_op_0_platform` has one and
`alsps_platform` does not, which looked like the difference between the
sensor that works and the one that does not. It is not: OxygenOS's own
`msmnile_alsps.json` declares `alsps_platform` with `.config`, `.als`,
`.cct`, `.prox` and no `.placement`. The served registry is faithful to the
vendor.

**`rail_on_state`.** The working SAR asks for state 1, the failing ALS/prox
for state 2 — the only differing power field between two sensors on the same
I2C bus instance, and the firmware carries `i2c_power_on failure` and
`i2c_pwr failure: on:%d status: %d`. Tested by editing
`alsps_platform.config` to 1 and rebooting:

```
sars            7335663959f5698867456bc70a6c70ca
ambient_light   no SUID
proximity       no SUID
rgb             no SUID
```

No change. The vendor value 2 was restored.

## The address split, restated

Both ALS candidates sit on bus instance 3:

| group | I2C address | DRI IRQ |
| --- | ---: | ---: |
| `tcs3701_platform` | 57 (`0x39`) | 117 |
| `alsps_platform` | 70 (`0x46`) | 120 |
| `sx9324_op_0_platform` (works) | 40 (`0x28`) | 96 |

The live com-port signature recorded in
[the TCS3701-only capture](2026-08-20-tcs3701-only-slpi-coredump.md) is
`slave=0x46`, three times — so it is the OnePlus `sns_alsps` combo driver
that instantiates ALS, proximity and CCT, not `sns_tcs3701`. That capture
also shows its I2C ULog containing only QDI setup and
`qdi root waiting for callback`, with no transaction at all.

Worth noting alongside: the I2C QDI handle in that dump is `0x1038` and the
platform-table handle here is `0x1030`. Both are QDI handles into the root
PD, which places the platform-table read on the same sensor-PD → root-PD
boundary as the stalled I2C open.

## Baseline after this work

Phone restored and verified: 441 registry entries, 66 config files, the five
factory `devinfo` entries present, `alsps` `rail_on_state` back to 2, all
three remote processors running, and `sars` publishing
`7335663959f5698867456bc70a6c70ca` as the positive control.
