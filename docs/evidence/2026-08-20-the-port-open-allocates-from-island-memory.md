# What actually gates the port open: an island-memory allocation

Date: 2026-08-20

> **Current status:** the title records the hypothesis that started this
> investigation, not its conclusion.  The island allocator was subsequently
> proved healthy, and disabling the sensor framework's island mode did not
> restore the missing sensors.  The latest corrected state is summarised in
> [Sensor-PD clock state and the island-mode control](2026-08-20-sensor-pd-clock-and-island-control.md).

The chain is now followed end to end, from the ALS driver's decoded state to
the instruction that decides whether a bus port exists.

## The path

The driver's state, read out of a coredump, is fully populated — slave 0x46,
400 kHz both ways, bus instance 3, DRI 120, both rail names — and carries
structure pointers at `+0x60`. One of them, `0xb20426b0`, holds the two
com-port entry points `0xb205e668` and `0xb205e684`.

`0xb205e684` is the transfer path, and it opens with the gate:

```
b205e684: r4 = memub(r0+#0x24)
b205e688: r4 = and(r4,#0x3)
b205e68c: if (!cmp.eq(r4,#0x3)) jump 0xb205e6b4     ; leave, doing nothing
```

Both low bits of the port object's flag byte must be set. They are set in one
place only, at `0xb205e250`:

```
b205e21c: callr r2                       ; handlers[bus_type] -> +0x10
b205e224: p0 = cmp.eq(r0,#0); if (p0) jump 0xb205e250
b205e22c: r2 = and(r2,#0xfd)             ; failure: clear bit 1
b205e250: r2 = or(r2,#0x3)               ; success: set bits 0 and 1
b205e254: memb(r16+#0x24) = r2
```

So everything hangs on the `+0x10` method of the bus handler returning zero.
For I2C that handler is `0xb2042738` and the method is `0xb205ee48`; for SPI,
`0xb2042984` and `0xb2064d6c`.

## What that method does

Both are the same shape:

```
b205ee54: r2 = memub(r16+#0x18)          ; bus instance
b205ee58: r2 = add(r2,#-0x1)
b205ee60: if (cmp.gtu(r2,#0x18)) jump <fail>   ; instance must be 1..25
b205ee70: call 0xb2065728                ; allocate 0x18 bytes
b205ee74: r1:0 = combine(#0x18,#0x2)     ;   from pool 2
b205ee7c: memw(r16+#0x20) = r17
b205ee80: if (r17 != 0) jump <continue>
b205ee90: call 0xb205057c                ; log, string 0xb204eda0
b205ee94: call 0xb2065728                ; retry
b205ee98: r1:0 = combine(#0x18,#0x0)     ;   from pool 0
b205eeac: if (r17 == 0) jump <fail>
```

The ALS's instance is 3, so the range check passes. What remains is the
allocation: **0x18 bytes from pool 2, falling back to pool 0**. If both fail
the method returns non-zero, the flag byte is never set, and the port silently
never opens — no ULog record, because the only complaint goes to diag.

That matches every observation: configuration complete, files all read, nothing
logged, no GPI channel, nothing on the wire.

## Why pool 2 is the suspect

Pool 2 is island memory. The firmware carries
`oplus_alsps_island.c:s_head did not init`, and the ALS, the IMU and the
magnetometer all have island variants (`sns_alsps_sensor_island`,
`sns_lsm6dsm_hal_island`). The two families that *do* reach the wire,
`sx932x`/`sx9324` and `ak0991x`, would then be the ones whose allocation
succeeds or which do not need pool 2.

## How to settle it

`0xb2065728` is the allocator and its first argument is the pool id. Reading
it, and reading the pool descriptors it indexes out of a coredump, says
directly whether pool 2 exists and has room. That is a bounded read, and it
either names the fault or eliminates the last hypothesis standing.

## The allocator and its pools

`0xb2065728` is the pool allocator, `r0` the pool id and `r1` the size:

```
b206572c: r2 = #0x4
b2065738: if (!cmp.gtu(r2,r16)) jump <assert>     ; pool id must be < 4
b206573c: r2 = +mpyi(r16,#0x28)                   ; descriptor stride 0x28
b206574c: r0 = memw(r2 + ##0xb20429d0)            ; pool table
b2065758: if (r17 == 0) ...                       ; allocation failed
```

The table at `0xb20429d0` holds four descriptors. Their static initialisers,
which the sensor PD's copy at physical `0x97ab3028` reproduces byte for byte:

```
pool 0 : start b2542b48  end b2542c10  id 1  size 0x180000   (1.5 MB)
pool 1 : start b23c2a80  end b23c2b48  id 2  size 0x25800    (150 KB)
pool 2 : start b20101d0  end b2010298  id 3  size 0x400      (1 KB)
pool 3 : start b2035a98  --            --    --
```

**Pool 2, the one the port open asks first, is the smallest by three orders of
magnitude** — a 1 KB arena whose descriptor spans 200 bytes — and each port
costs 0x18 bytes. That is a hard ceiling of a few dozen ports at best, and
plausibly far fewer once other island users take their share.

It also matches the strangest observation of the session: with the SAR present
two ports are allocated and the ALS gets none; with the SAR's registry entries
removed, a different driver, `ak0991x`, takes a port instead. That is what a
small first-come arena looks like from the outside.

Its backing store at `0xb20101d0` lies past segment 18's file size, so it is
BSS and only exists at run time. The root PD's copy reads as 208 zero bytes,
which is expected — the root PD does not use it, exactly as with the bus
handler table at `0xb2042668`, whose root copy is also null while the sensor
PD's copy is populated.

## The one question left

Locate the **sensor PD's** copy of `0xb20101d0` and read it. If the arena is
full, or was never initialised, the port open fails there and everything above
follows. Finding it needs the PD's mapping for segment 18's BSS, which the
seg12/seg15 offset of `0x2E4CC2A0` does not cover — that offset was measured
between file-backed copies, and a BSS region has no content to match on.

The practical way in is the allocator itself: `0xb2065e24` and `0xb2065ac4`,
called on the path above, take the descriptor as an argument, so a coredump
taken with a breakpoint-free read of the driver state — the ALS state at
`0x9869d3f8` carries the port object pointer — leads to the arena directly
rather than by search.

## The driver has its dependencies resolved

Reading around the ALS state turns up its dependency SUID table, and every
entry is filled with the same values the host's own client sees:

```
+0xa0  ...b441 25 5e 59 27 7f 00 a7 54 27 e1…   registry  e12754a7007f27595e2541b470…
+0xb0  46 11 56 e2 e3 cf b6 e2 d0 3d ee 6e…     interrupt 45d03dee6ee3cfb6e2461156e2f58f61
+0xc0  65 63 ee 7e 3b b6 8a 31 08 b9 78 7c…     timer     d708b9787c3bb68a316563ee7e3ba813
```

So the driver has looked up and received the SUIDs of the registry, the
interrupt sensor and the timer — the three services a hardware driver needs
before it can open a port. Nothing is outstanding on that side either.

Scanning blindly for the port object does not work: a loose signature over the
whole dump returns 3501 candidates, almost all coincidence. The anchored route
is the one to take — follow the pointer out of the driver's own state rather
than search for the shape.

## Nothing has ever been allocated from pool 2

The arena spans 200 bytes, `0xb20101d0` to `0xb2010298`, which makes any
pointer into it a tight signature. Searching the whole coredump for a 4-byte
value in that range finds **eight**, and every one of them is the arena's
*start* address `0xb20101d0` — the descriptor's own field, copied about. Not a
single interior pointer exists anywhere in DSP memory.

An arena that has served even one allocation would show interior pointers held
by whoever owns the block. There are none. Combined with its backing store
reading as 208 zero bytes, the conclusion is that **pool 2 has never handed out
a block**, either because it was never initialised or because every request
failed.

That is consistent with every observation in this investigation: the port open
asks pool 2 first, its failure is silent, the flag byte is never set, the
transfer path refuses, no GPI channel is allocated, and nothing reaches the
wire — for the ALS, the IMU and the magnetometer alike.

It also fits the exception. The SAR does reach the wire, and the same searches
that find the ALS's decoded platform values find nothing equivalent for it, so
the SAR takes a different route to its port and does not depend on this arena.

## What that makes the next question

Not "why does the allocation fail" but "who was supposed to initialise pool 2,
and does that code run at all". The pool table at `0xb20429d0` carries only
static initialisers — start, end, id, size — and the sensor PD's copy
reproduces them byte for byte, so nothing has updated the descriptor either.
The allocator's helpers `0xb2065e24` and `0xb2065ac4` and the assert path at
`0xb2065780` are the places to read.

## Correction: pool 2 is healthy, and the allocation is not the blocker

The section above is wrong on two counts and is corrected here rather than
deleted, because the mistake is instructive.

**First mistake: the wrong copy again.** Segment 18's content appears at three
physical addresses in the coredump — `0x982d9000` (the root PD's, matching the
MDT), `0x97a96000`, and `0x98680000`. Found by taking twenty-five dense 64-byte
witnesses out of `slpi.b18` and locating each; all twenty-five agree on all
three bases. The live sensor-PD copy is `0x98680000`. Reading pool 2's object
there:

```
pa 0x986901d0
  +0x20  abcddcba b20102a0 00000161 000257f0
  +0x30  0000e556 00010e02 00001000 b2065d68
  +0x40  b2065d7c abcdabcd 00000002 00010c50
```

Heap magic `abcddcba` and `abcdabcd`, a live vtable method at `+0x3c`, and the
accounting: **58710 bytes free of 69122**. Pool 3 next to it reads free 0 of 5,
so the fields are what they look like.

**Second mistake: the descriptor's first two words are not arena bounds.** They
are the pool object pointer and a second pointer. Treating `0xb20101d0` to
`0xb2010298` as a 200-byte arena, and concluding from an absence of interior
pointers that nothing had ever been allocated, was reading the wrong thing
entirely. The real arena is 69 KB.

So an allocation of 0x18 bytes from pool 2 succeeds with room to spare. **The
port open is not blocked at the allocation.** The gate is still the flag byte
at `+0x24`, and the reason it is never set lies past the allocation, in the
rest of `0xb205ee48`.

The extrapolation that produced the first wrong address is also worth
recording: the offset between a root copy and a PD copy measured on
file-backed segments does not carry to a neighbouring segment, and does not
carry to BSS. Each segment's PD copy has to be located on its own content.

## The instruction that actually refuses

With the allocation cleared, the rest of `0xb205ee48` reads straight through,
and the refusal is four instructions past it:

```
b205eeb0: r3 = #0x0
b205eeb4: r2 = memw(r16+#0x14)
b205eeb8: r1 = memub(r16+#0x18)          ; bus instance
b205eebc: call 0xb205ef78                ; the real bring-up
b205eec0: r0 = memub(r16+#0x4)
b205eec8: p0 = cmp.eq(r0,#0x0)
          if (!p0.new) jump 0xb205ef3c   ; <- non-zero at +0x4: give up
...
b205ef3c: call 0xb20658ec                ; free the block just allocated
b205ef40: r0 = memw(r16+#0x20)
b205ef44: r17 = #0x1                     ; return 1 = failure
b205ef44: memw(r16+#0x20) = #0
b205ef4c: r0 = r17 ; return
```

So the port object's **byte at `+0x4` must be zero**. If it is not, the freshly
allocated block is released, the function returns 1, the caller clears bit 1
instead of setting bits 0 and 1, the flag byte at `+0x24` never reaches 3, the
transfer path at `0xb205e684` refuses, and nothing reaches the wire — silently,
because the only complaint is a `(file, line)` diag descriptor, not a string
that ULog would carry.

The success path is the mirror: `r17 = #0x0` at `0xb205ef50`, reached when
`memw(block+0) == 0`.

The known port-object layout so far:

```
+0x04  byte    must be zero, or the open refuses   <- the gate
+0x08  word    logged alongside +0x04 on the failure path
+0x14  word    passed to the bring-up call
+0x18  byte    bus instance
+0x1c  byte    bus type, indexes the handler table
+0x20  word    block allocated from pool 2, freed again on failure
+0x24  byte    flags; bits 0 and 1 both set means the port is usable
```

What `+0x4` holds is the next thing to name. The failure-path log takes it and
`+0x8` as arguments, so the diag message would say it outright — the strings
live in a table indexed by the file id in the descriptor (`0x7b` here), which
is worth resolving on its own since it would give plain text for every message
on this path.

## The message table resolves, and the refusal really is silent

The compact descriptors on this path — `0xb204eda0`, `0xb204edb8`,
`0xb204edc4`, `0xb204edd0` — are `(file, line)` words, file id `0x7b`, and they
sit in a per-file block that also carries the message pointers. Decoding
`0xb204ed90..0xb204ef00` gives plain text for the whole of
`sns_com_port_i2c.c`:

```
line 257   sns_com_port_i2c.c:Alloc I2C config in DDR
line 280   ...
line 292   sns_com_port_i2c.c:i2c_open failure. i2c...
line 303   sns_com_port_i2c.c:i2c_power_on failure...
           sns_com_port_i2c.c:i2c_open success. hnd...
           sns_com_port_i2c.c:Unable to malloc in DDR
           sns_com_port_i2c.c:i2c_transfer failed
           sns_com_port_i2c.c:i2c_pwr failure: on:%
```

`Alloc I2C config in DDR` is the line reached when the pool 2 allocation
returns null and the code retries from pool 0 — which confirms the reading of
that retry, and confirms it is a fallback rather than a fatal path.

More usefully, it settles the character of the refusal. The branch at
`0xb205eec8`, taken when `memub(r16+0x4)` is non-zero, jumps straight to
`0xb205ef3c` — free the block, return 1 — **without passing any of these log
sites**. The success path at `0xb205ef50` logs `i2c_open success`; the two
failure messages, `i2c_open failure` and `i2c_power_on failure`, belong to
other branches. So the path actually taken emits nothing at all, on any
channel, which is exactly why nothing has ever shown up in ULog or in the diag
descriptors held in memory.

That closes the question of why the failure is invisible. What `+0x4` holds
remains open, but the file is now fully readable: every message in
`sns_com_port_i2c.c` can be resolved by line, so walking the function with the
line numbers in hand is straightforward.

## Correction: the branch tests the setup return value, not `+0x04`

The preceding two sections misread a Hexagon instruction packet. The call at
`0xb205eebc` and the load printed at `0xb205eec0` execute in the same packet:

```
b205eeb0: r3 = #0
b205eeb4: r2 = memw(r16+#0x14)
b205eeb8: r1 = memub(r16+#0x18)
b205eebc: { call 0xb205ef78
b205eec0:   r0 = memub(r16+#0x4) }
b205eec4: { if (p0.new) r1 = add(r17,#0)
b205eec8:   p0 = cmp.eq(r0,#0); if (!p0.new) jump 0xb205ef3c }
```

The load supplies `r0` as an argument to `0xb205ef78`. The compare in the next
packet observes the value that the call returned in `r0`. It does **not**
compare the byte loaded from the port object. A non-zero return from
`0xb205ef78` is therefore the silent refusal.

The object layout can now be named by matching the accesses against Qualcomm's
SSC com-port sources. The local firmware remains authoritative, but the public
SDM670 implementation provides the missing type names:

```
object +0x04  com_config.slave_control       0x46
object +0x08  com_config.reg_addr_type
object +0x0c  com_config.min_bus_speed_KHz   400
object +0x10  com_config.max_bus_speed_KHz   400
object +0x18  com_config.bus_instance        3
object +0x1c  bus_info.bus_type
object +0x20  bus_info.bus_config
object +0x24  power/open flags
```

The four-byte shift comes from the sync com-port handle at the beginning of
the private object. The observed `0x46` is the sensor's I2C slave address, not
an invalid flag. This also explains why the same object contains 400 kHz and
bus instance 3 at the offsets used by the call.

`0xb205ef78` is the resource-setup stage. It manages a small shared-resource
table and eventually calls `0xb206769c` with the bus speed and instance. Only
after this stage succeeds does `0xb205ee48` proceed to the operations matching
`i2c_open()` and `i2c_power_on()`. The reference implementation's equivalent
setup can fail when the platform has no configuration for the requested bus
instance, or when setting the serial-engine clock fails.

The next question is consequently precise: **why does the low-level setup for
I2C instance 3 at 400 kHz fail?** The live shared-resource table and the path
below `0xb206769c` must distinguish a missing QUP/SE device configuration from
a clock/resource transition failure. The island allocator, decoded sensor
configuration, slave address, and bus-speed fields are no longer suspects.
