# The sensor bus dies because the arbiter's master table has one entry

Date: 2026-08-19

> **Superseded.** The conclusion below is wrong: the arbiter works, votes real
> bandwidth, and resolves masters 131, 112, 76, 180 and 52. The two clients it
> refuses name BLSP masters that no SM8150 topology has, so that failure is the
> same under OxygenOS. See
> [2026-08-19-sensor-core-registers-no-driver.md](2026-08-19-sensor-core-registers-no-driver.md).
> The address arithmetic and structure layouts here remain correct and useful.

The full chain, end to end, read out of the DSP's own memory rather than
inferred. This replaces the "capacity" reading of the previous note.

## The method that unlocked it

The static firmware could not answer the question, because the structures
involved are built at runtime. The **coredump is the DSP's RAM**, so they are all
in it. Its segments are physical, offset from the DSP's virtual addresses by a
constant:

```
DSP 0xb0100000  <->  physical 0x97300000     relocation 0x18E00000
```

which is the same constant `slpi-ulog-coredump.py` uses for its heap pointers.
With that, any DSP address can be read as it was when the DSP was running.

## The chain

**1. What the QUP drivers ask for.** The bandwidth vector is the fourth argument
of `npa_create_sync_client_ex`, passed in `r4`, and it is static: `0xb002b220`
for SPI, `0xb002b210` for I2C. Both hold the same two pairs:

| pair | master | slave |
| ---: | ---: | ---: |
| 0 | **41** (0x29) | 0 |
| 1 | **39** (0x27) | 0 |

Slave 0 is fine on its own: the arbiter services `MID 180 -> SID 0` during the
same boot.

**2. Where it is refused.** The arbiter's create-client callback is
`0xb0165708`, reached from the live resource object. It reads `r22 = r1 >> 3`,
so its second argument is a pair count in units of eight: `0x8` is one pair,
`0x10` is two. For each pair it calls the route lookup at `0xb016688c`, and on a
NULL result jumps to `0xb0165828`, which sets `r19 = #0x4`. That is the `error: 4`.

**3. Why the lookup returns NULL.** It is an array index, nothing more:

```
r5 = memw(##0xb05c911c)        ; the arbiter context
r3 = memw(r5+#0x4)             ; number of masters
p0 = !cmp.gtu(r3,r0)           ; master id beyond the table?
if (p0) return NULL
r4 = memw(r5+#0x8)             ; table base
r4 = memw(r4+r0<<#0x2)         ; table[master]
```

**4. What the table actually contains.** From the coredump:

```
context @0xb05c911c = 0xb032a09c
  number of masters = 1
  table base        = 0xb032a094
```

**One entry.** Every master id from 1 upwards is out of range, 39 and 41
included. Those two addresses are in the firmware's static data, so the arbiter
is still holding its built-in fallback: the real topology was never installed.

**5. Where the real topology should come from.** The single write to that
pointer is at `0xb0166630`:

```
r0 = ##0xb026d2fc              ; "icb_info"
call 0xb0164ca0                ; device-configuration lookup
p0 = cmp.eq(r0,#0x0)
if (p0) jump 0xb016673c        ; not found: give up, keep the fallback
memw(##0xb05c911c) = r0        ; found: install it
```

`0xb0164ca0` attaches the DAL device `/icb/arb` and reads its `icb_info`
property. The bail path is the one taken.

**6. And the data is present.** The device-configuration tables are in the image:
`/icb/arb` has an entry at `0xb0262758` with a property blob at offset `0x48d8`,
whose contents are well-formed, and `icb_info` is in the name pool at
`0xb025e58a`. The live device-configuration handle at `0xb05c0638` is non-null,
so that subsystem came up.

## So

The sensor buses are dead because the DSP's bus arbiter is running with a
one-entry master table, and it is running with a one-entry master table because
its `icb_info` device-configuration property lookup came back empty at boot —
even though the property is in the image and the configuration subsystem
initialised.

That is a much smaller question than any asked so far, and it is the last one:
**why does the `/icb/arb` `icb_info` lookup fail at runtime.** The lookup itself
is `0xb014788c`, called with the context at `0xb05c062c`, live value
`0xb025aba4`. Both are readable in the coredump, and the property encoding is
`{type|name-offset, value}` pairs against a name pool that resolves `0x31f` to
`icb_info`.

Nothing about this is host-side, which is consistent with every host-side lever
having been tested and found irrelevant. But it is now a concrete, bounded
question rather than a wall.

## The data is loaded correctly

Comparing the coredump against the firmware image at the three addresses that
matter — the `/icb/arb` property blob at `0xb025f47c`, the name pool holding
`icb_info` at `0xb025e58a`, and the device table entry at `0xb0262758` — all
three are **byte-identical**. The segment loaded exactly as PAS was given it.

The live attach state confirms the rest:

```
0xb05c0628 = "/icb/arb"      the device name
0xb05c062c = 0xb025aba4      the configuration blob base
0xb05c0630 = 0x000048d8      the device's offset, matching the table entry
0xb05c0638 = 0xb05c9008      a live configuration handle
0xb05c9104 = 1               the arbiter's init-once flag, set
0xb05c911c = 0xb032a09c      but the context is still the static fallback
```

So the device attach succeeded, the blob is present and intact, the offset is
right, and the property is in the pool. The lookup of `icb_info` nevertheless
returned nothing.

That is a logic failure inside the DSP's own configuration search
(`0xb014788c`), not a missing file, a bad load, or anything the host provides.
Decoding it means working out the property encoding — `{type|name-offset,
value}` pairs terminated by `0xff00ff00`, against a name pool whose base still
has to be pinned down — and reading that function. Everything needed is in the
coredump and the image.

## Two more checks, both negative

**The lookup does not take its logged error paths.** `0xb014788c` carries
`DALPROP_PropsInfo is NULL- pszName:%s` and
`Failed- pszDevName:%s DALPROP_PropsInfo:0x%x`. Neither pointer appears in the
capture, so the search ran normally and simply returned "not found" through a
path that logs nothing.

**The one segment outside the carveout is the signature, not configuration.**
`slpi.mdt` segment 1 loads at physical `0x98700000`, which is the first address
past `slpi_mem` and is where mainline reserves `ipa_fw_mem`. It is also absent
from the coredump, which looked like a strong lead. It is not: the segment holds
an X.509 blob, `QUALCOMM Attestation CA`, `SecTools Test User`, dated 2023-03-13.
That is the image's attestation metadata, which PAS hands to TrustZone through
`qcom_mdt_pas_init` rather than placing in the subsystem's memory. Its absence
from the DSP's RAM is correct.

## Decoded: the configuration does not describe the masters the drivers ask for

The device-configuration format resolves cleanly once the indirection is read
properly. `0xb014788c` does not use the context pointer as the data base: it
loads `r18 = *ctx`, then `r19 = *r18`, and the device's list is `r19 + offset`.

```
*0xb05c062c = 0xb025aba4      the configuration object
*0xb025aba4 = 0xb025d180      the actual data base
 0xb05c0630 = 0x48d8          the /icb/arb offset
 -> property list at 0xb0261a58
```

Entries are `{header, value}` pairs separated by `0xff00ff00`. The header's low
bits are a name offset into a pool based three bytes below the data base, and
the value is an index into a table at `*(0xb025aba4+4)` = `0xb025abb8`.

Decoding the `/icb/arb` list gives an unmistakably interconnect-shaped property
set: `icb_info`, `…ROUTES`, `…DDR_BW_TABLE`, `…AHBIX_BW_TABLE`,
`…MEMORY_DESCRIPTORS`, `…POWER_DOMAIN_DESCRIPTORS`,
`…MASTER_PROGRAMMING_SPEEDS`. `icb_info` is header `0x1280140d`, value `0x495`,
and `table[0x495]` = `0xb032f5e0`.

That data is a list of master descriptors, an identifier and a small attribute
each:

```
130,0  131,0  132,0  133,0  134,0  143,0  144,2  145,2  146,2
147,2  148,2  149,1  150,…  151,…  152,…
```

Fifteen masters, **130 through 152**. The QUP drivers ask for masters **39 and
41**. They are not in it.

## What that means

Two findings that point the same way:

- the arbiter never installed this configuration at all and is still running its
  built-in one-entry fallback, which is why the lookup path bails;
- and had it installed it, masters 39 and 41 would still be absent, so the QUP
  clients would be refused just the same.

So the sensor buses cannot come up with the configuration this image resolves.
Either a different configuration set is meant to be selected on this hardware,
device configuration on Qualcomm being keyed by platform, or the QUP masters are
meant to resolve through a table other than the one `/icb/arb` publishes.

Everything here is inside the DSP: its own firmware, its own configuration, its
own arbiter. No part of it is supplied by the host, which is consistent with
every host-side lever having been tested and found irrelevant.

## Root cause: the `icb_info` variable is never populated

The value table is made of eight-byte entries, `{size, pointer}`, not four. With
that corrected:

```
icb_info   index 0x495   size 4   storage 0xb05c5fd0
```

A four-byte property whose storage lives at `0xb05c5fd0`, an address that has **no
backing in the static image** — it is zero-initialised memory. Read out of the
coredump:

```
0xb05c5fd0 = 0x00000000
```

The property is found. Its value is null. And the installer is

```
call 0xb0164ca0                ; returns the property value
p0 = cmp.eq(r0,#0x0)
if (p0) jump 0xb016673c        ; null: give up
memw(##0xb05c911c) = r0        ; otherwise install
```

so it gives up, and the arbiter keeps the one-entry fallback it was built with.

That is the whole failure, and every step of it has now been read out of the
running DSP rather than inferred:

1. something should write the ICB topology pointer into `icb_info` at
   `0xb05c5fd0`; on this system nothing ever does, and it stays zero
2. the arbiter's installer therefore bails and keeps its built-in fallback,
   a table of one master
3. route lookup is a bounds-checked array index, so every master from 1 up is
   out of range
4. the QUP bandwidth clients ask for masters 41 and 39 against slave 0 and are
   refused with error 4
5. `spi_plat_init` returns, the SSC QUP microcode is never loaded and its GPI
   never initialised
6. SPI never runs at all, I2C reaches the wire against an unstarted engine and
   collects NACKs
7. no sensor is ever detected, and the sensor core answers every SUID lookup
   with nothing

The topology data itself is in the image. Master descriptors are DevCfg values
indexed by master id — entry 41 is an eight-byte record at `0xb032e4d8`, and the
underlying array runs from master 1 to 168 with 39 and 41 present. What is
missing is the pointer that would let the arbiter reach any of it.

## And nothing in the image writes it

`0xb05c5fd0` falls inside segment 5, `va=0xb0319000 fsz=1226964 msz=5382144`, so
it is past the loaded data and zero-filled at load. Searching the disassembly
for a writer finds none — not as an absolute immediate, and not as a
`base + offset` store either, which was checked separately because Hexagon
usually builds addresses that way and a plain search would miss it.

So the pointer the arbiter needs is zero-initialised memory that no code in this
firmware ever fills in. The only reference to the address anywhere in the six
megabytes is the device-configuration table entry that names it as `icb_info`'s
storage.

## `icb_info` is the only property without a value, and two paths both bail

Decoding every property of `/icb/arb` and comparing its storage in the image
against the coredump settles what kind of failure this is:

| property | size | storage | static | live |
| --- | ---: | --- | --- | --- |
| …`_ROUTES` | 4 | `0xb0326728` | `00000005` | `00000005` |
| …`DDR_BW_TABLE` | 4 | `0xb0326748` | `00000001` | `00000001` |
| …`POWER_DOMAIN_DESCRIPTORS` | 4 | `0xb0326740` | `00000003` | `00000003` |
| …`_DESCRIPTORS` | 4 | `0xb0326710` | `00000007` | `00000007` |
| **`icb_info`** | 4 | `0xb05c5fd0` | **no backing** | **`00000000`** |

Thirty-three properties carry real values, present in the image and unchanged at
runtime. Exactly one does not: `icb_info` is the only one whose storage lies in
zero-filled memory, and it is the only one that reads null. The configuration
mechanism is working perfectly; this single value is missing from it.

And the firmware only ever reads that one. Across the whole image there are two
calls to the property reader, `0xb0166624` and `0xb01670d4`, and both ask for
`icb_info`. Nothing reads `…_ROUTES`, `…DDR_BW_TABLE` or any of the others
through that interface — they are counts describing a structure that something
else is expected to have assembled and published.

Both readers behave identically:

```
b01670b4: call 0xb0164bc4            ; attach /icb/arb   (succeeds)
b01670d4: call 0xb0164ca0            ; read icb_info     (returns null)
b01670d8: if (r0 == 0) jump away     ; bail
b01670e0: memw(##0xb05c9120) = r0    ; otherwise publish
```

and live, `0xb05c9120` holds `0xb032a09c`, the same static one-master fallback as
`0xb05c911c`. Two independent initialisation paths, the same empty result.

So the sensor DSP expects the interconnect topology pointer to be handed to it
already populated, and on this system it never is. Everything else it needs is
present: the master descriptors indexed by identifier, the route counts, the
bandwidth tables. Only the pointer that reaches them is missing, and no code in
the image writes it.
