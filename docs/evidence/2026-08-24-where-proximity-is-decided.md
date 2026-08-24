# Where proximity is decided

Date: 2026-08-24

Disassembly of `sns_tcs3701` in the running firmware, following the request path
end to end. It does not fix proximity, but it names the byte that gates it and
the question that has to be answered.

## The path a request takes

`set_client_req` at `0xb20a9b84`. Its message-id dispatch splits the id into
two bytes, `bitsplit(r2,#0x8)`:

| id | handling |
| --- | --- |
| `0x710`, `0x711`, `0x712` | OnePlus display messages — setting, refresh rate, DC mode |
| `0x203` | flush; this is the `state+0x23d` block, and both its branches converge |
| anything else | `call 0xb20a91c0`, where the real work happens |

**Correction to an earlier note:** the display messages are `0x710`–`0x712`, not
`0x10`–`0x12`. The low byte is what the dispatch compares after the split, and
sending 16, 17 and 18 — as an earlier test did — reaches nothing.

## The decision, and the byte it sets

`0xb20a91c0` calls one decision function **twice**, once per sub-sensor:

```
b20a91d4:  r2 = #0x1          -> call 0xb20a9368     ; ALS
b20a928c:  r2 = #0x2          -> call 0xb20a9368     ; PROX
```

Confirmed two ways. The function selects the sub-sensor name byte by byte from
that argument — `'A','L','S','_'` for 1, `'P','R','O','X'` for 2, both appended
to `amsTCS3701` — and each call is followed by its own log line:

```
0xb20528bc  line 216   TCS3701 ALS:  rr %u sr %u num_clients %d
0xb20528c8  line 235   TCS3701 PROX: rr %u sr %u num_clients %d
```

Each call returns a one-byte flag, and the caller uses it directly:

| sub-sensor | flag set | flag clear |
| --- | --- | --- |
| ALS | bit 0 of `state[0]`, `state[0x230] = 1` | bit cleared, `state[0x230] = 0` |
| **proximity** | bit 1 of `state[0]`, **`state[0x231] = 1`** | bit cleared, **`state[0x231] = 0`** |

## What the flag depends on

Inside `0xb20a9368`, with the sub-sensor type in `r17`:

1. the name is built on the stack;
2. the output flag is set to **zero**;
3. a virtual call is made through the instance, `memw(instance+0)` then `+0x8`,
   with the built name as its second argument;
4. **if it returns null, the function leaves and the flag stays zero**;
5. otherwise the request's message id is split the same way, and only
   `0x201` streaming or `0x202` on-change reach `b20a9538`, which sets the flag.

The `num_clients` field in the log line is the same quantity: the driver is
asking how many clients want this sub-sensor.

So proximity is disabled because the driver counts no client for it — while the
light sensor, from the same function on the same request, counts one.

## What is verified and what is not

Verified: the two call sites and their constants, the name bytes each selects,
the two log descriptors, the two enable bytes, and that the flag starts at zero
and is set only on the `0x201`/`0x202` path.

Not verified: what the virtual call at step 3 actually is. It is called with the
instance and the sub-sensor name, which fits a lookup of client requests by
sensor UID, but the vtable slot has not been identified. The published proximity
UID does decode to exactly `amsTCS3701PROX__`, so a name mismatch is not the
explanation.

## The measurement this sets up

`state[0x230]` and `state[0x231]` are single bytes at a fixed offset in the
sensor state, and the sensor state is locatable in a coredump — the same
technique that read `who_am_i` and the hardware-present flag out of the SAR's
state. A dump taken with a proximity subscription live would show whether
`0x231` is zero, confirming the gate, and whether `0x230` is one beside it.

That is the next step, and it is a measurement rather than another reading.
