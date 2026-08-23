# Proximity reaches its chip, and one earlier defect claim is withdrawn

Date: 2026-08-23

A coredump taken while a proximity subscription was live, with every other SEE
client stopped so the circular I2C buffer would still hold the attempt. It does
not fix proximity, but it moves the failure and it corrects an earlier note.

## Method

`iio-sensor-proxy` stopped and `monitor-sensor` killed first — the Plasma shell
claims proximity at session start, so the daemon is a subscriber that would
otherwise keep the buffer turning. Coredump enabled on `remoteproc0`, an
on-change proximity request issued and held, then the SLPI crashed. Twenty
megabytes, `logs/2026-08-23-prox-dri/prox-subscribed.elf`.

## The bus is not the problem

Transfers to slave `0x39` — the TCS3701 — appear right up to the crash:

```
ts=6801097202  extra=[0x02b08090, 0x04003901, ...]
ts=6801111984  extra=[0x02b080f0, 0x00003901, ...]
ts=6801097287  extra=[0x02b080b0, 0x00003902, ...]
```

Seven of them survive in the retained window, and `0x39` is the only slave in
it. The `I2C_error` buffer holds twelve entries and **every one of them is at
`ts` ≈ 658–659 million**, against ≈ 6801 million for those transfers — an order
of magnitude earlier, which is boot-time probing. There is no error anywhere
near the proximity request.

So the SLPI opens the port, talks to the chip at the right address, and gets
answers. Whatever silences proximity is downstream of that.

This weakens the reading carried from the 00121 disassembly, where the failure
was localised to `r24 = memw(r16+#0x08) == 0`, "failed to initialize bus
interface hw context". That may still be a real code path, but it is not what
this firmware is doing: a driver that never initialised its bus context would
not be transacting on it.

One caveat, stated because it matters: these transfers cannot be attributed to
the proximity request specifically. The ALS shares the chip and the port, and
the pattern is periodic. What the trace establishes is that the port is open and
error-free during the window, not that proximity itself drove it.

## RETRACTED: the missing interrupt id was not a defect

An earlier note recorded that the SLPI's `InterruptController` "configures ids
142–152, never 120 — a real defect". **That is withdrawn.** The distinct ids
this log registers are

```
3  7  40  126  142  144  146  148  150  152  164  173  199
```

Proximity's `dri_irq_num` is 117 and it is absent — but the accelerometer's is
**132 and it is equally absent**, and the accelerometer works, streaming at
25 Hz through `is_dri 1`. A log that does not mention the interrupt of a sensor
that demonstrably uses one is not tracking sensor GPIO interrupts at all, so
absence from it proves nothing about proximity.

The four GPIO interrupt buffers — `GPIOInt`, `PdcGpioInt`, `DirConnGpioInt`,
`SummaryGpioInt` — are all still empty (`write=0`) under this firmware too, and
the same argument applies to them: the working accelerometer would have to
appear there and does not.

## Where this leaves proximity

Narrowed, not solved. Established by measurement, not inference:

- the driver is present and instantiated — the sensor publishes a SUID and a
  full attribute set (`name: tcs3701`, `vendor: ams AG`, `stream-type:
  on-change`, `available: yes`);
- its registry is byte-identical to what OxygenOS 10.0.13 wrote on this unit;
- `is_dri` and `hw_id` both change the served registry and change nothing else;
- no other SEE client is starving it;
- the I2C port to its chip is open and error-free.

The request is accepted, no configuration event comes back, no sample, no error.
That is a decision taken inside `sns_tcs3701` between accepting the request and
emitting anything, and the driver has messages for exactly that region — offset
calibration failure, a 100 ms timeout, contaminated and saturated first
readings. They go to diag, which this port has no transport for, and that
remains the blocker.
