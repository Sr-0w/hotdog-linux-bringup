# The island region is opaque to address search — a documented boundary

Date: 2026-08-23

Recording this so the next person does not spend a day rediscovering it, as
I did.

## The pattern

Everything the sensor drivers live in — the island data at `0xe06a8000`,
the island strings at `0xe65exxxx`, the sensor descriptor table around
`0x97aa4000` — is reachable by *nothing* that an address search can find.
Repeatedly, across eight different handles:

| looked for | result |
| --- | --- |
| descriptor addresses `0xe06b401c`…`0xe06b4094` as immediate or pointer | none |
| driver `init` addresses (`0xb21c7aa8`, `0xb21c7b14`, `0xb21d9af0`) as `call`, immediate or data | none |
| registry group name strings (`lsm6dsm_0_platform` at `0xe06f5694`, `alsps_platform` at `0xe06f6fe8`, …) | none |
| `ak0991x_hal_table` / `ak0991x_hal_table2` at `0xe65ed641` / `0xe65ed653` | none |
| `mmc5603x_hal_table` / `mmc5603x_hal_table2` at `0xe65ed7ae` / `0xe65ed7c1` | none |
| the `mmc5603x_%d%s` name builder `0xb21d751c` as a call target | none |
| the mmc5603x diag descriptor `0xb2229e2c` | none |
| the two framework descriptors at `0x97add0dc` / `0x97addbf4` | none |

## Why it is not a finding about the failure

The crucial control: **this is equally true of the drivers that work.**
`sns_ak0991x` instantiates, opens its bus and probes correctly, and its
`hal_table` string and source-file string are just as unreferenced as
`sns_mmc5603x`'s. So "unreferenced" carries no information about whether a
driver runs.

Three explanations were tried for the opacity and all three are wrong:

- **GP-relative addressing** — all 498 `gp+#offset` operands are in `seg04`
  and `seg06`, both root-PD. The sensor PD's `seg14` has none.
- **A missing executable segment** — every executable segment with content in
  the image is disassembled. Segment 21 is executable with `fsz` 0, and the
  coredump region assigned to it turns out to hold sensor-PD *data*, proven
  by it containing the ALS part-name table.
- **A wrong VA↔PA mapping** — the mapping is verified by size-matching and
  cross-checked: the descriptor at `0x97aa406c` holds exactly the sixteen
  bytes `sns_lsm6dsm`'s init at `0xb21c7b14` writes one at a time.

## What this means practically

Address-based static analysis of the SEE registration path is exhausted.
Continuing requires a different instrument — recovering the sensor PD's
runtime register state, or driving the registry sensor over QMI to ask it
directly what it holds, or dynamic tracing that this port does not currently
have.

The empirical route, by contrast, is productive and cheap: the bus-scanner
technique in
[the address note](2026-08-23-two-sensors-are-at-the-wrong-address.md)
answered two hardware questions in four reboots.
