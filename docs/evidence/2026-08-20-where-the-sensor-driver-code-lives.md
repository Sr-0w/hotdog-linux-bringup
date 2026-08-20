# Where the sensor driver code lives, and why the disassembly missed it

Date: 2026-08-20

The remaining question is narrow: `sx932x` and `ak0991x` reach the I2C wire,
`lsm6dsm`, `alsps` and `mmc5603x` never do, with the same firmware, the same
registry shape and the same QUP core. Answering it means reading those drivers'
code. This records what is needed to do that, because two false starts cost
time.

## The segment map, by permission

```
seg  va          fsz       perms
2    0xb0100000  10012     RX      platform, root PD
3    0xb0103000  169036    RWX
4    0xb012d000  2012176   RX
5    0xb0319000  1226964   RW
6    0xb0000000  178580    RWX
7    0xb002c000  93708     RX
8    0xe65e0000  57769     R       sensor PD data
9    0xe65c5000  82        R
10   0xe65c6000  8192      R
11   0xe65c8000  29248     R
12   0xe06a8000  350196    R
13   0xe06fe000  268       R
14   0xb2100000  1011393   RX      SEE code
15   0xb21f6ed0  218008    RW
16   0xb222c268  160224    R       SEE strings
17   0xb2254000  28676     RW      (msz 6.8 MB, heap)
19   0xb2035b70  53156     RW
20   0xb2042b18  447428    RX
21   0xb20b0000  0         RX
```

The `0xe0…` and `0xe65…` segments are **read-only data**, not code — so the
sensor drivers do execute out of segments 14 and 20, which the reassembled ELF
and `llvm-objdump` already cover. The earlier worry that the disassembly missed
the sensor PD's code was wrong.

## Two search mistakes worth not repeating

**Signed immediates.** `llvm-objdump` prints large Hexagon constants as negative
signed hex, so an address like `0xb222e918` appears as `##-0x4ffd16e8`. Grepping
for `##0xb222e918` finds nothing and looks like "no references exist". Always
search both forms.

**Two copies of the same data.** The root PD and the sensor PD each have their
own copy of the SEE data segments, at different physical addresses. Reading a
structure at its root-PD address can show it empty while the sensor PD's copy is
fully populated — which is exactly what happened with the bus handler table at
`0xb2042668`: zero in the root copy, and `{I2C: 0xb2042738, SPI: 0xb2042984}` in
the sensor PD's copy at physical `0x97ab2cc0`. The com-port layer is fine.

## What is still unresolved

The registry group names the drivers read — `lsm6dsm_0_platform.config`,
`alsps_platform.config`, `alsps_platform.cct.fac_cal` — live in segment 12, the
sensor PD's read-only data, and no code in segments 14 or 20 references them by
the address the MDT gives for that segment. The sensor PD maps that data at its
own virtual address, so reaching the driver code that uses those names means
reconstructing the PD's address space first: segment 12 is a container holding
copies of several segments' data (the seg19 content was found inside its
physical range), and the mapping is not the simple constant offset the root PD
uses.

That reconstruction is the next piece of work. With it, the comparison is
direct: disassemble `sns_sx932x`'s init, which reaches the wire, against
`sns_lsm6dsm`'s and `sns_alsps`'s, which do not, and read what differs between
the registry callback and the com-port open.

Note also `alsps_platform.cct.fac_cal`: the driver carries that group name as a
static string, the registry has no such entry, and the file service was never
asked for it. Whether the driver stops before requesting it, or resolves it
some other way, is unknown and worth settling in the same pass.
