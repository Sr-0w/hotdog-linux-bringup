# The sensor bus dies because the arbiter's master table has one entry

Date: 2026-08-19

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
