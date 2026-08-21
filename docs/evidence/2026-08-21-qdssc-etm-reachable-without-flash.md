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
