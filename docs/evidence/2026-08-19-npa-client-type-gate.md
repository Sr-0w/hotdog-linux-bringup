# The QUP drivers ask the bus arbiter for a client type it does not offer

Date: 2026-08-19

## Tooling first

LLVM ships a Hexagon backend, and the local toolchain has it, so the sensor DSP
can be disassembled rather than guessed at. Two small tools now live in
`tools/slpi/`:

- `build-slpi-elf.py` reassembles `slpi.mdt` plus `slpi.b00..b21` into a single
  ELF. The `.mdt` already holds the ELF and program headers; only the segment
  bytes need placing at the offsets those headers name. The result loads as
  `elf32-hexagon` and `llvm-objdump -d` disassembles 1.7 million lines of it in
  about four seconds.
- `slpi-resolve-strings.py` turns a logged format-string pointer back into its
  string, reading from the same segments.

Both must be pointed at the image the handset actually runs, taken from
`/mnt/modem_b/image`. Using an OTA copy is what produced days of wrong readings.

One disassembly detail worth knowing: `llvm-objdump` prints these addresses in
signed form, so `0xb029c5a3` appears as `##-0x4fd63a5d`. Searching for the
unsigned spelling finds nothing.

## The call that fails

`spi_plat_init` and its I2C counterpart both end in the same call, and the
arguments are legible:

```
b0034d04: r0 = ##0xb002cfb1          ; "/icb/arbiter"
b0034d0c: r1 = ##0xb002cfbe          ; "SPI_QUP_DDR"
b0034d14: r3:2 = combine(#0x10, ##0x400)
b0034d18: call 0xb01e2bcc            ; npa_create_sync_client_ex
```

```
b00312c8: r0 = ##0xb002c027          ; the I2C resource name
b00312d0: r1 = ##0xb002c034          ; the I2C client name
b00312d8: r3:2 = combine(#0x10, ##0x400)
b00312dc: call 0xb01e2bcc
```

Those two client-name pointers, `0xb002c027` and `0xb002c034`, are exactly the
two that the NPA log printed unresolved.

## The calls that succeed

Every other client created on `/icb/arbiter` in this firmware passes `0x8`
where the QUP drivers pass `0x10`:

| site | client | third argument |
| --- | --- | ---: |
| `b01bf770` | `tmsDDRVote` | `r3 = #0x8` |
| `b0152a70` | (from a table) | `combine(#0x8, r17)` |
| `b01f6554` | (from a table) | `combine(#0x8, ##0x1000)` |
| `b0034d18` | `SPI_QUP_DDR` | `combine(#0x10, ##0x400)` |
| `b00312dc` | the I2C client | `combine(#0x10, ##0x400)` |

## Where the error number comes from

Inside `npa_new_client`, the resource's own callback decides:

```
b01e2da8: r2 = memw(r24+#0x14)      ; the resource's definition
b01e2dac: r3 = memw(r2+#0x10)       ; its create-client callback
b01e2db4: r1:0 = combine(r19,r16)   ; r1 is that third argument
b01e2db8: callr r3
b01e2dc0: p0 = cmp.eq(r0,#0x0)      ; zero means success
b01e2dc8: memw(r29+#0x8) = r0       ; otherwise r0 becomes "(error: %d)"
b01e2dd8: r2 = ##-0x4fd63a5d        ; "FAILED npa_new_client ... (error: %d)"
```

So **the 4 in `error: 4` is the return value of `/icb/arbiter`'s own
create-client callback**, called with the argument that differs between the
working and failing sites. There is also an earlier gate,
`p0 = bitsset(r2, r20)` at `b01e2cd8`, checking a requested type against a mask
carried by the resource; it takes a different error path, which is not the one
observed, so that gate passes.

The arbiter's definition sits at `0xb032a0c8`: name `/icb/arbiter`, units
`Arbitration Request`, max `0xffffffff`, and `0x809` at offset `0x10`.

## What this means

The QUP drivers ask the sensor DSP's bus arbiter for a client of a kind it
declines to create, and everything else follows: no bandwidth client, no QUP
bring-up, no SPI at all, and an I2C controller that reaches the wire and
collects NACKs from unpowered-looking parts.

The firmware is the handset's own and byte-identical to what stock loads, so
this cannot be a static mismatch. Either the arbiter is initialised differently
here, or its callback depends on state the host establishes. That callback is
the next thing to disassemble, and it is now reachable: it is
`memw(memw(resource+0x14)+0x10)`, and the resource is the one defined at
`0xb032a0c8`.

## Correction: it is a capacity, not a type

Following the registers through both frames changes the reading.

`npa_create_sync_client_ex` at `b01e2bcc` marshals its arguments as
`r17:16 = combine(r2,r0)`, `r21:20 = combine(r3,r4)`, `r19 = r1`, then calls the
worker at `b01e2c64` with `r2` and `r3` preserved in order. The worker keeps
`r20 = r2` and `r19 = r3`, and:

- `bitsset(mask, r20)` at `b01e2cd8` tests **`r2`**, which is `0x400` at every
  call site including the failing ones. That gate passes, and its error path is
  a different message from the one observed.
- `create_client` at `b01e2db8` is called `r1:0 = combine(r19,r16)`, so its
  second argument is **`r3`** — the value that is `0x8` where clients succeed
  and `0x10` where they fail.

So the client type is the same everywhere. What differs is the second argument
to the arbiter's own create-client callback: the QUP drivers ask for `0x10`
where every other client asks for `0x8`, and the callback returns 4.

For a bus arbiter taking a vector client, that argument is the size of the
bandwidth vector: the QUP drivers want room for sixteen master-slave pairs and
the arbiter will only hand out eight. That is a capacity inside the DSP's own
arbiter, not a malformed request, which is consistent with everything else
observed: the resource is healthy, other vector clients work, and only these two
are refused.

Why the arbiter's capacity would be short here and not on stock remains the open
question, and it is the same question as before, only sharper.
