# The gates, found in the drivers themselves

Date: 2026-08-23

Disassembly of the running firmware, `SLPI.HY.2.2-00083`. This does not fix
either sensor, but it replaces "silent for unknown reasons" with named branches
at known addresses.

## Method, including the two mistakes worth avoiding

`llvm-objdump --triple=hexagon` disassembles the `.mbn` directly — it is a
32-bit Hexagon ELF with twenty `PT_LOAD` segments. The sensor drivers live in
segment 17 (`0xb204a7f0`, executable) and segment 11 (`0xb2100000`), their
message strings in segment 13 (`0xb22210f8`, read-only).

Finding which code uses a message took two failed attempts:

- **searching for pointers to the string** finds nothing, because the pointer is
  to the *start* of the full `sns_sx9324_….c:text` string, not to the fragment
  being searched for;
- **`add(pc,##imm)`** is not the mechanism either — there are 26 in a 970 KB
  segment.

The messages are reached through 12-byte descriptors, `(file:line, argc,
msg_ptr)`, and the code loads the descriptor address as an immediate:

```
b20a48c4:  r3:2 = combine(#0x1,##0xb205208c)
```

so grepping the disassembly for descriptor addresses finds every call site.
Fifty-nine descriptors for `sns_sx9324`, sixty-five for `sns_tcs3701`, each
carrying its source line number.

## The SAR has an explicit hardware-present gate

```
ligne 549   sx9324 who am i is 0x%x
ligne 569   sensor:%d initialize finished
ligne 574   sx9324 HW absent
ligne 165   sar sample rate: %d, report rate: %d,  sar present %d
```

and the check itself, at `0xb20a48d0`:

```
r2 = memub(r29+#0xa7)      ; the byte read back from the chip
r2 = and(r2,#0xfe)         ; mask bit 0
p0 = cmp.eq(r2,#0x22)      ; accept 0x22 or 0x23
if (!p0.new) jump ...      ; otherwise: HW absent
```

On success the driver sets `memb(r19+#0xb7) = 1` and stores the identity it read
at `memh(r19+#0x19c)`. A `sar present` flag then gates reporting — which is
consistent with everything observed: the sensor is published, the request is
accepted, a configuration event comes back, the driver transacts with `0x28`,
and no sample is ever produced.

`sns_sx932x` is not an alternative: byte for byte the same comparison, at the
same address `0x28`. There is no second driver to try.

## RETRACTED by measurement: the SAR chip is present and correctly identified

The identity gate above is real code, but it is **not** what stops the SAR. The
driver stores what it read at `state+0x19c` and raises a flag at `state+0xb7`,
and both can be read out of a coredump once the state is located.

Locating it needed a calibration, and the registry handler provides one. At
`0xb21d6728` the SAR's own `sns_sx9324_sensor.c` logging reloads the values it
parsed, which names their offsets:

| field | offset | value on this unit |
| --- | --- | --- |
| `bus_type` | `+0x50` | 0 |
| `slave_control` | `+0x54` | 40 (`0x28`) |
| `min`/`max_bus_speed_KHz` | `+0x5c`, `+0x60` | 400, 400 |
| `bus_instance` | `+0x64` | 3 |

Scanning the coredump for that signature finds exactly two `sns_sx9324` states:

```
base 0x986a7f9c   present(+0xb7)=0   who_am_i(+0x19c)=0x0000
base 0x986a8860   present(+0xb7)=1   who_am_i(+0x19c)=0x0023
```

**`0x23` is precisely what the driver accepts**, and the present flag is set. So
the chip is fitted, powered, addressed correctly and identified — the `HW absent`
branch is not taken. The I2C traffic to `0x28` seen earlier was this successful
read.

The second state, all zeros, is the duplicate candidate: `sx932x_0_platform.config`
and `sx9324_0_platform.config` are identical, both bus 3 slave `0x28`, so two
drivers probe the same chip. Removing the three `sx932x` config files and
rebooting changes nothing, so the collision is not the cause either, and they
were restored.

What this leaves: a SAR whose hardware is present and identified, whose request
is accepted, which transacts with its chip, and which never reports. The
remaining path is the polling timer. The instance state carries the interval at
`+0x4c` and a 64-bit timer value at `+0x50`, written at `0xb20a45e8` and read
back at `0xb20a4560`; reading those needs the *instance* state base, which this
note does not have — the calibration above locates the *sensor* state.

## Proximity: RETRACTED, the byte at +0x23d is not the gate

An earlier version of this note read `sns_tcs3701`'s `set_client_req` at
`0xb20a9c40` as returning early when a byte at `state+0x23d` is zero, and called
that the reason no instance is created. **Reading the full branch shows both
paths converge:**

```
b20a9c4c:  if (byte == 0)  jump 0xb20aa264
b20a9c68:  else            call 0xb20aa404      ; which does memb(r18+#0) = 0
b20a9c70:                  jump 0xb20aa264
```

Zero or not, execution continues at the same address. So `+0x23d` is a
"something is pending" flag that gets serviced and cleared, not a gate. The
location is right — that code is genuinely `sns_tcs3701`'s `set_client_req`,
confirmed by the descriptor it loads at `0xb2052934` — but the meaning was
over-read from a partial branch.

Proximity's failure is still that no instance is created and no configuration
event is emitted. Where that is decided is not established.

**RETRACTED: the capability-bit story below was a different driver.** An
earlier version of this note said the byte was written at `0xb21c81c4` from a
capability bit at `r22+0x87`. That write is in
`sns_lsm6dsm_sensor_instance.c:inst_init`, identified from the message
descriptor its neighbouring code loads — the accelerometer, not the ALS. The
offsets coincided; a read in one driver was linked to a write in another. The
same mistake produced a wrong attribution twice in one session, because several
drivers carry byte-identical message text: searching the image for
`interrupt_num:%d interrupt_pull_type` finds `sns_mmc5603x_sensor.c` first, not
the `sns_sx9324` copy. **Resolve the descriptor, never the string fragment.**

What survives is the read, which is in `sns_tcs3701` and is real: a zero byte at
`state+0x23d` returns from `set_client_req` without creating an instance. What
sets it is not yet known. The code passes `add(r19,#0x23d)` to a function at
`0xb20aa404`, so `+0x23d` is the start of a structure rather than a lone flag,
and that function is where to look next.

## The driver listens to the display

Unexpected, and probably relevant. Among `sns_tcs3701`'s descriptors:

```
ligne 874   SNS_OP_IFACE_MSGID_DISPLAY_SETTING
ligne 877   SNS_OP_MSGID_DISPLAY_FRESH_RATE
ligne 880   SNS_OP_MSGID_DISPLAY_DC_MODE
```

This is an under-display sensor, so OxygenOS feeds it the panel's refresh rate
and DC-dimming state to compensate for OLED infrared leakage. Nothing on this
port sends those messages. Whether the capability bit above is related has not
been established.

## What this changes

Nothing works that did not work before. What changes is that the next step is
addressable rather than speculative:

- for the SAR, read `memh(state+0x19c)` — the identity the chip actually
  returned — from a coredump, which needs the driver's state base and therefore
  a struct-layout calibration this note does not have. Two candidates were
  located at `0x986a8008` and `0x986a88cc` by the platform-config signature
  (`irq 96` beside `slave 40`, `bus 3`, `400 kHz`);
- for proximity, find what sets bit 1 of the capability byte at `r22+0x87`.

## Eliminated today, each with the served registry read back afterwards

| sensor | tried | result |
| --- | --- | --- |
| SAR | `is_dri` 1 → 0 | configured, silent |
| SAR | `res_idx` 2 → 0 | configured, silent |
| SAR | requested rate swept 1 → 100 Hz | configuration event at every rate |
| SAR | `vdd_rail` `sensor_vddio` → `sensor_vdd`, matching the working tcs3701 | configured, silent |
| SAR | GPIO 96 released from Linux before the SLPI arms | configured, silent |
| proximity | `is_dri`, `hw_id`, subscription order, client contention, calibration override | no configuration event in any case |

The `vdd_rail` asymmetry is real — the SAR is the only sensor whose `vdd_rail`
and `vddio_rail` name the same rail — and it is what OxygenOS wrote, so it was
restored after the test.
