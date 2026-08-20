# What actually gates the port open: an island-memory allocation

Date: 2026-08-20

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
