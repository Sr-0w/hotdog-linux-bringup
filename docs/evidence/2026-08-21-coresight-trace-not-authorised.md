# CoreSight capture never starts: the trace hardware is not authorised

Date: 2026-08-21

Found while exercising the QDSSC path without a flash, and it bears directly
on what a remote ETM lease can hope to demonstrate.

## enable_sink succeeds, the hardware does not

`tmc_etr0` accepts being armed and reports itself enabled, but its own
management registers say nothing happens:

```
sink disarmed   authstatus=0x23  ctl=0x0  rwp=0x0
sink armed      enable_sink=1  authstatus=0x23  ctl=0x0  rwp=0x0  rrp=0x0  mode=0x0
after 3 s       ctl=0x0  rwp=0x0
```

`CTL` bit 0 is `TraceCaptEn`. It stays clear with the sink armed, and the write
and read pointers never move, so no trace is captured and none is retained.
That is also why `/dev/tmc_etr0` refuses to open with `EINVAL`: there is no
sysfs buffer to read, before or after disarming.

The same holds with the SLPI's ETM enabled — `SET_ETM(1)` confirmed by
`GET_ETM`, sensor traffic driven through `ssc-client.py` — and the buffer stays
empty.

## What the authentication status says

```
tmc_etr0   authstatus = 0x23
tmc_etf0   authstatus = 0x00
```

CoreSight `AUTHSTATUS` carries four two-bit fields, where `0b00` is not
implemented or not enabled, `0b10` implemented but disabled and `0b11`
implemented and enabled. `0x23` is `0b0010_0011`:

```
NSID  [1:0] = 0b11   non-secure invasive debug      enabled
NSNID [3:2] = 0b00   non-secure NON-INVASIVE debug  not enabled   <- trace
SID   [5:4] = 0b10   secure invasive                disabled
SNID  [7:6] = 0b00   secure non-invasive            not enabled
```

Trace is non-invasive debug, and it reads as unavailable. The ETF reporting
`0x00` across the board points the same way. The ETR itself is clocked and
reachable — its registers read back meaningful values — so this is an
authorisation state, not a missing clock.

## Consequence for the remote ETM work

The S63 objective is a remote ETM trace. On this phone, with these fuses, the
capture side cannot arm, so no trace can be produced no matter what the source
does. That is independent of `coresight-remote-etm`, of the `ssc-etm` device
tree node, and of the flash: the QDSSC control path works, the sink does not.

Combined with the other finding — `SET_ETM(0)` is refused with QMI error 17,
so the disable half of the milestone cannot be confirmed either — the milestone
as written is not reachable on this hardware.

What would have to change first is the debug authentication: non-invasive
debug enabled for the non-secure world. On a production Qualcomm device that is
a fuse and TrustZone matter, not a kernel one, and it should be settled before
another lease is spent on the trace path.

## What still works, and is worth keeping

The QDSSC control path itself: `GET_ETM` answers on the sensor DSP, the ADSP
and the modem from the stock kernel with no flash, and `SET_ETM(1)` takes
effect and is visible in `GET_ETM`. That is a usable channel for asking the DSP
about its state; it is only the trace capture that is blocked.
