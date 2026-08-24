# My decoder was hiding four working sensors

Date: 2026-08-24

The SAR, `amd`, `rmd` and `device_orient` were reported silent throughout the
previous session. They were not. Every tool I wrote accepted only message id
1025, the generic `sns_std_sensor_event`, and **each SEE sensor publishes under
its own event id**.

## What they actually emit

Subscribing to everything and printing whatever comes back, with no id filter:

| sensor | event id | first value |
| --- | ---: | --- |
| accel, gyro, mag, temperature, ambient_light | 1025 | streaming as before |
| **SAR** | **1026** | `[0.0, -10.0, 11865.0, 0.0]` |
| **amd** | **772** | state |
| **rmd** | **772** | `[1.0]` |
| **device_orient** | **776** | `[4.0]` |
| proximity | — | nothing, not even an indication |
| tilt | — | nothing |

`11865` is a raw capacitance reading. The SAR's configuration event carries
`NORMAL`. It has been working the whole time.

## How it was found

Not by disassembly. The gesture-detection script listed `amd`, `rmd`, `tilt` and
`device_orient` as silent alongside proximity and the SAR — and those four are
**algorithms derived from the accelerometer**, which streams perfectly. Four
software sensors failing at once is not a hardware fault, so the common factor
had to be the client. Dumping the raw bytes of one of them showed a well-formed
indication carrying id 772 that the decoder was discarding.

The indication structure, for whoever writes the next client:

```
field 2 { 0x0d <id fixed32>  0x11 <timestamp fixed64>  0x1a <payload> }
payload: 0x0a <len> packed floats,  or  0x08 <varint>
```

## What this cost

Every "silent sensor" conclusion in the previous session's notes about the SAR
is wrong, along with the reasoning built on it: the identity-gate hypothesis,
the rail asymmetry test, the ODR sweep, the duplicate-candidate removal and the
GPIO 96 investigation were all chasing a sensor that was reporting normally.

The coredump work stands and was right for a different reason than I thought:
`who_am_i = 0x23` and `present = 1` were correct readings of a **working**
driver, not evidence against a failure that never existed.

## The trap that made it plausible

A second filter bug in the same tools reinforced it. `sns_std_sensor_event`
1025 is not the only thing a streaming sensor sends: 1022 is the calibration
event, whose bias vector is usually zero. Taking it for a sample reads as a dead
sensor — which is exactly what once produced a false "magnetometer at zero"
while it measured 168 µT. Both filters are now explicit in the shared decoder,
one accepting every plausible id, the other refusing to treat 1022 as data.

## What is still silent

**`proximity`, and only proximity.** `tilt` was listed here too and that was
wrong as well: it answers under event id **774** with an empty payload, since it
is a trigger and the event itself is the signal. It fires rarely enough that a
six-second window saw nothing and a fifteen-second one caught two — a third way
for a working sensor to look dead, after the wrong event id and the calibration
event.

Proximity is different in kind, verified over fifteen seconds on-change and ten
seconds each at 5 Hz and 1 Hz: thirty-two bytes every time, the QMI
acknowledgement alone, no indication under any id. Working sensors sampled in
the same conditions answered normally.

That makes it ten of eleven, with proximity the single exception.
