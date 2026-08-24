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

## Measured: the proximity enable byte is zero

A coredump taken with both the light sensor and proximity subscribed, and the
instance state located by its calibration block — the nine floats of
`tcs3701_platform.als.fac_cal` in registry order, starting `1156.547607`,
`0.000000`, `1.378319`.

A single byte signature is far too weak here: scanning for
`state[0x238] == 1` alone produced a hundred candidates. Requiring instead that
the offset from the calibration block to the state base be **the same across
several anchors** leaves two, and one of them carries exactly the `state[0]` the
code predicts:

```
base 0x986a902c   state[0] = 0x01   [0x238] = 1 (ALS)   [0x239] = 0 (PROX)
base 0x986a938c   state[0] = 0x01   [0x238] = 1 (ALS)   [0x239] = 0 (PROX)
```

`state[0] = 0x01` is bit 0 set and bit 1 clear: light enabled, proximity not.
That is the same fact stated twice in the same structure, by two fields the
driver writes from the same flag, on two independent instances.

The other surviving offset gives `state[0] = 0xf5`, which is not a coherent
enable word, and is treated as coincidence.

**So the reading is confirmed by measurement rather than by another reading.**
The decision function returns zero for the proximity sub-sensor, the caller
clears bit 1 and writes `state[0x239] = 0`, and nothing downstream ever runs.
The question is now narrow and singular: why the driver counts no client for
`amsTCS3701PROX__` while counting one for `amsTCS3701ALS___`, from the same
request, in the same call.

## The virtual call, identified

Not by guessing at a vtable layout — the sensor PD holds no absolute pointers,
so walking from the state back to the instance finds nothing — but from the
call's own argument signature, which is unambiguous.

The same slot, `memw(instance+0)` then `+0x8`, is called twice:

```
b20a93f4:  p0 = or(p0,!p0)      ; unconditionally TRUE
b20a940c:  r2 = p0              ; third argument = true
b20a9414:  callr r3             ; r0 = instance, r1 = &suid on the stack
b20a9424:  if (result == 0) return with the flag still zero

b20a9540:  p0 = and(p0,!p0)     ; unconditionally FALSE
b20a954c:  r2 = p0              ; third argument = false
b20a9554:  callr r3             ; same slot, same instance, same suid
b20a955c:  if (result != 0) loop back to 0xb20a9464
```

Arguments `(instance, sensor_uid*, bool)`, called once with true and then
repeatedly with false while the return stays non-null. That is
`sns_sensor_instance_cb::get_client_request(this, suid, first)`, and the loop it
drives is what produces the `num_clients` field in the log line.

The second argument is a **16-byte SUID built on the stack**, not a string:
`amsTCS3701` plus `ALS_` or `PROX`, padded to sixteen — which is exactly what
the published UIDs decode to.

## Where that leaves it

The driver asks the framework, on the shared instance, for a client request
against the proximity UID. It gets nothing. For the light UID, in the same call,
a few instructions apart, it gets one.

So this is no longer a driver question. **The framework holds no client request
for `amsTCS3701PROX__` on that instance**, although a client — this port's own
test client, and `iio-sensor-proxy` before it — subscribed to exactly that UID
and received a QMI acknowledgement for it.

Two readings fit and they are not distinguishable from here:

- the request never reaches `sns_tcs3701` at all, so nothing is ever attached to
  the instance. Consistent with there being no configuration event, no I2C
  traffic and no error;
- the request is attached to a different instance from the one this call
  inspects, so the lookup is correct and looking in the wrong place.

Separating them means observing whether `set_client_request` is entered for the
proximity sensor, which is what diag would show and what this port cannot read.
