# The sensor descriptor table

Date: 2026-08-23

Structural groundwork for whoever continues. This does not explain why the
accelerometer fails, but it names the data structure the answer lives in.

## Layout

Island data around `0x97aa4000` (physical; VA `0xe06b4000` under the
`fw seg12 = 0xe06a8000 ↔ cd 0x97a98000` mapping) holds an array of sensor
descriptors:

```
struct {
    sns_sensor_uid suid;      // 16 bytes
    uint32_t       struct_len; // 0x14 or 0x18
    void (*init)(...);
    void (*deinit)(...);
    ... 2-3 more entry points
};                             // stride 0x28 for the 0x18 form
```

Confirmed by cross-check rather than pattern-matching alone: the descriptor
at `0x97aa406c` carries the exact 16 bytes that `sns_lsm6dsm`'s init at
`0xb21c7b14` writes one at a time (`cd 4b 1a 6d 68 da 4a 77 85 ab 46 e2 cd a5
68 0b`), and `0x97aa4070` holds that init's address. The same holds for
`0x97aa4044` / `0xb21c7aa8`.

## Which sensors have static descriptors

Filtering the whole island segment for entries whose 16 SUID bytes are
neither zero, nor code pointers, nor island pointers — the filter matters,
because a naive scan matches every run of function pointers and also matches
float tables (`0x3f800000`, `0xbf800000` are 1.0f and -1.0f, and two `alsps`
coefficient blocks look like SUIDs without it):

| descriptor | init | driver |
| --- | --- | --- |
| `0x97aa401c` | `0xb21c75e4` | lsm6dsm |
| `0x97aa4044` | `0xb21c7aa8` | lsm6dsm |
| `0x97aa406c` | `0xb21c7b14` | lsm6dsm |
| `0x97aa4094` | `0xb21cbe18` | lsm6dsm |
| `0x97add0dc` | `0xb219b8a8` | framework |
| `0x97addbf4` | `0xb21b5798` | framework |

`resampler`, `timer`, `registry`, `interrupt`, `sars` and the ALS have **no**
static SUID anywhere — theirs are produced at run time.

## The discriminator that looked promising and is not one

"Only the failing driver has static SUIDs" was the obvious reading, and it is
wrong. Searching a live coredump for each of these SUIDs outside the island
segment:

```
framework A  0x97c20e3c  0x97f469a0     <- live band
framework B  0x97c21954  0x97f48520     <- live band
lsm6dsm a-d  0x982e70xx  0x9868e0xx     <- root-PD and sensor-PD static copies only
```

The live sensor objects sit around `0x97f4xxxx`–`0x97f5xxxx` (the ALS is at
`0x97f51f60`, the SAR at `0x97f57d00`). Both framework sensors with static
descriptors are there. All four LSM6DSM descriptors appear only as the two
static image copies, `0x3A7000` apart — the root-PD/sensor-PD offset.

So a static descriptor is instantiated perfectly well in general. The
LSM6DSM's four are simply never acted on.

## A convention trap worth writing down

A SUID has two representations and mixing them silently produces empty
results. `ssc-client.py` prints `"%016x%016x" % (high, low)` where `low` and
`high` are the two little-endian 64-bit halves — so the printed string is
**not** the byte order in memory. For the ALS:

```
memory bytes  62 61 43 54 52 4c 22 35 | 39 31 91 2c 43 5d 52 5f
printed form  5f525d432c913139 35224c5254436162
```

Searching a dump for the printed string, or feeding memory bytes to a
printed-form decoder, finds nothing and looks like a negative result. It cost
one wrong "the ALS SUID is absent" reading in this session's working notes.

## Where the answer must be

Nothing references these descriptors by address — no code immediate, no data
pointer, in either the image or a live dump. They are reached by base plus
index, with the base computed rather than stored. Finding the iterator, and
what it consults before calling each `init`, is the remaining work.

## Why no address search finds the iterator — corrected

**An earlier version of this section blamed GP-relative addressing. That was
wrong.** All 498 `gp+#offset` operands are in `seg04` and `seg06`, which are
**root-PD** segments at `0xb012d000` and `0xb0000000`. The sensor PD's code in
`seg14` contains **none**, so GP-relative addressing cannot explain anything
about the sensor PD's registration path.

Two other candidates were checked and are also dead:

- every executable segment carrying content in the image *is* disassembled
  (2, 3, 4, 6, 7, 14, 20). Segment 21 is executable with `msz` `0x377000` but
  `fsz` 0, which looked like 3.5 MB of runtime-loaded code never examined. It
  is not: the coredump region assumed to be it turns out to hold the sensor
  PD's **data** copy — it contains the ALS part-name table (`stk33502`,
  `stk32600`) that also sits in the island static data, at a constant offset.
  The VA assignment was mine and it was wrong.

So the honest statement is narrower: nothing in the disassembled image
references these descriptors by absolute address, and the reason is not yet
known.

So the negative results throughout this session are explained, not
mysterious: searching the image or a dump for `0xe06b401c`, `0xe06b4044`,
`0xe06b406c` or `0xe06b4094` as an immediate or as a stored pointer finds
nothing because no such absolute reference exists. The same is true of the
`init` addresses themselves — no `call 0xb21c7b14`, no data pointer to it
outside its own descriptor.

Assuming `GP` equals the island segment base `0xe06a8000` makes
`gp+#0xc07c` land exactly on the `struct_len` field of the LSM6DSM
descriptor at `0x97aa406c`, which looked like a hit. It is not one: the two
matching operands are in `seg04`, which is **root-PD** code with a different
`GP`, and their surrounding disassembly is desynchronised — data being
decoded as instructions.

**Practical consequence for whoever continues:** do not spend time on
address-based searches for the registration path. Either recover the sensor
PD's `GP` (from a thread context, or by anchoring one GP-relative access
whose target is independently identifiable), or work forward from the SEE
registration entry point rather than backward from the descriptors.
