# The sensor DSP's ETM control answers on the stock kernel, no flash needed

Date: 2026-08-21

S63 was built to add `coresight-remote-etm` so the SLPI's ETM could be driven.
The service it drives is already live on the baseline the phone is running.

## What the driver actually does

`coresight-remote-etm.c` is a QMI client, nothing more:

```c
#define QDSSC_QMI_SERVICE_ID    0x33
#define QDSSC_QMI_GET_ETM_REQ   0x002b
#define QDSSC_QMI_SET_ETM_REQ   0x002c
```

and it picks its peer by instance, mapped from the remote pid:

```c
{ 1, 2, "modem" }, { 2, 5, "adsp" }, { 3, 8, "sensor" },
{ 4, 3, "wlan" },  { 5, 13, "cdsp" },
```

so `qcom,remote-pid = <0x03>` means QDSSC instance 8. `SET_ETM` carries one
TLV, type 0x01, a four-byte state.

## The service is already there

`qrtr-lookup` on the running baseline, service 51 = 0x33:

```
51  1   2  0   29   CoreSight remote tracing service
51  1   3  0  105
51  1   5  5    6
51  1   8  9    6   <- instance 8, node 9: the SLPI
51  1  12  9   11
```

Instance 8 on node 9 is exactly what the driver would bind to. Nothing about
that depends on the driver existing, on a device-tree node, or on S63.

## Reading the state from userspace

`helpers/qdssc-etm.py` speaks it directly over QRTR:

```
QDSSC instance 8 at node 9 port 6
bound to node 1 port 16402
-> 0001002b000000
<- 0201002b000e000204000000000010040000000000
reply msg=0x002b  result: ok, error 0
  tlv 0x10: 0
```

The sensor DSP answers, the result is success, and **the ETM state reads 0 —
tracing disabled**. That is a live read from the stock kernel, with no flash,
no module and no device-tree change.

## What this changes

The remote ETM milestone does not have to wait on the flash. `GET_ETM` works
now; `SET_ETM` is the same message with a state TLV, and the CoreSight sinks
the trace would land in are already present and bound on this kernel —
`tmc_etr0`, `tmc_etf0`, `tmc_etf1`, `stm0`, fourteen devices in
`/sys/bus/coresight/devices`.

What S63 still buys is the in-kernel integration: a CoreSight source device
that the framework can enable as part of a path to a sink, rather than a raw
QMI poke. For establishing whether the SLPI will trace at all, the raw poke is
enough.

Runtime device-tree overlays are not available on this build — there is no
`/sys/kernel/config/device-tree/overlays` — so the `ssc-etm` node itself cannot
be added without a flash. That only matters for the framework path, not for
the QMI control.

## Enabling it destabilises the phone

`SET_ETM` was exercised against the sensor DSP, and the results matter for the
S63 plan.

**The driver's wire format is right.** Sending the state as one or two bytes is
rejected with `MALFORMED_MSG`; the four-byte form the driver declares
(`QMI_UNSIGNED_4_BYTE`, TLV type 0x01, request length 7) is accepted:

```
TLV 1 byte    -> result=1 error=1    (malformed)
TLV 2 bytes   -> result=1 error=1    (malformed)
TLV 4 bytes   -> result=0 error=0    (accepted)
```

**Enable works, and then the phone reboots.** `SET_ETM(1)` took the state from
0 to 1, confirmed by `GET_ETM`. Within minutes the phone rebooted on its own,
twice, and after the first of those the state still read 1. With the ETM back
at 0 it has been stable — 339 s of continuous uptime, SLPI running, no reboot:

```
+30s   uptime=189s  slpi=running  etm=0
+180s  uptime=339s  slpi=running  etm=0
```

The correlation is strong but not proof: this session had seen occasional
spontaneous reboots before. The plausible mechanism is that a trace source was
started with no sink path configured and, on mainline, no QDSS power or clock
votes behind it.

**Error 17 is not error 94.** The hardening commit maps
`QMI_ERR_NOT_SUPPORTED_V01` (94) to `-EOPNOTSUPP`. This device answers **17**
instead, on `SET_ETM(0)` while already disabled, and again on `SET_ETM(0)`
immediately after a successful enable. The driver would map that to
`-EREMOTEIO` and give up, and its pending-disable path would then never clear.
Worth reproducing before the next hardware run, because it lands exactly on the
disable-confirmation the S63 milestone depends on.

**State can survive a reboot.** After one reboot `GET_ETM` still returned 1; a
later boot returned 0. So the disable cannot be assumed to happen implicitly.

## What to do with this before flashing

None of this needed the flash to discover, and all of it changes the plan:

1. establish the sink path and the QDSS power/clock votes **before** enabling
   the remote ETM, or expect the phone to reboot under you;
2. handle error 17 in the driver, not only 94;
3. treat the remote state as sticky across reboot and always confirm it with
   `GET_ETM` rather than assuming a clean start.

## Corrected: enable is stable with a sink armed, and disable is refused

Two corrections to the section above, both from reading the replies properly.
An inline decoder was taking the result TLV at the wrong offset and printing
values like 256 and 4352; the helper parses correctly and the sequence below
uses the right offsets throughout.

**Enable is not inherently destabilising.** With `tmc_etr0` armed first —
`echo 1 > /sys/bus/coresight/devices/tmc_etr0/enable_sink`, sink reads 1, phone
steady for 60 s — the ETM was enabled and the phone stayed up through the whole
sequence, uptime running from 518 s to 635 s with the state at 1 for most of
it. The reboots happened in the earlier attempt, when the source was started
with no sink armed. That is consistent with the trace having nowhere to go, and
it makes arming the sink first a precondition rather than a nicety.

**Disable is refused, reproducibly.** With correct decoding:

```
etat de depart : 0
A. SET(1) direct       -> (result 0, error 0)   state = 1
B. malformed 1 byte    -> (result 1, error 1)   MALFORMED_MSG
C. SET(1) again        -> (result 0, error 0)   state = 1   (idempotent)
D. SET(0)              -> (result 1, error 17)  state = 1
```

and three further attempts, with the sink armed and then disarmed, all returned
`result: fail, error 17` with the state stuck at 1. Only a reboot cleared it,
and even that took a second one — a first reboot still read 1.

## What this means for the S63 milestone

The milestone is "a remote ETM trace with disable confirmed". On this device,
over this protocol, **the disable half cannot be confirmed**: `SET_ETM(0)` is
answered with error 17 every time, and the hardening commit maps only error 94.
The driver would return `-EREMOTEIO`, its `disable_pending` flag would stay
set, and by its own logic the next enable must first complete `SET_ETM(0)` plus
a `GET_ETM` confirmation — which cannot happen. The second enable would be
refused by the driver itself.

None of that needed the flash to find. It should be settled before the next
hardware lease, because it changes what the lease can hope to demonstrate.

## State left behind

ETM back to 0 after a reboot, sink disarmed, all three remote processors
running, `boot_b` unchanged at `d881abaf…`. Nothing persistent was modified.
