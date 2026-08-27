# The SLPI user PD is killed by its watchdog every 40 seconds

Date: 2026-08-27

Found while chasing DisplayPort, on `r14`. It is not a DisplayPort defect and
not caused by any change in this session; it was simply never looked for,
because nothing that samples state can see it.

## The cycle

```
qmi_decode_string_elem: String len 128 >= Max Len 65
failed to decode incoming message
qcom_q6v5_pas 2400000.remoteproc: fatal error received:
    err_qdi.c:964:EF:sensor_process:0x1:TMR_CLNT_1:0x82:dog_virtual_user.c:240:USER-PD DOG
remoteproc remoteproc0: crash detected in slpi: type fatal error
remoteproc remoteproc0: recovering slpi
remoteproc remoteproc0: remote processor slpi is now up
```

Six occurrences in the first 289 s of a boot, at 46.50, 86.67, 126.85, 167.02,
207.19 and 247.36 seconds. The interval is 40.17 s every time, which is what a
watchdog looks like, and `dog_virtual_user.c` says so outright.

Each cycle is preceded by the same QMI decode failure, so the shape is: the
kernel cannot decode an incoming message, never answers it, and the SLPI's user
protection domain waits for that answer until its watchdog fires.

## Why nothing caught it

`remoteproc` recovers within ~150 ms, so `state` reads `running` at any sampled
moment, and `HasAccelerometer`, `HasAmbientLight` and `HasProximity` all stay
`true` on SensorProxy. The runtime gate passes 35/35 through this. A subsystem
that restarts every forty seconds and answers correctly in between is invisible
to every check that asks whether it is up.

## Where the 65 comes from

`qmi_decode_string_elem()` rejects a string longer than the element's declared
`elem_len`. The only definitions in the kernel that declare 65 are the
protection domain registry ones, through
`char service_path[SERVREG_NAME_LENGTH + 1]` with `SERVREG_NAME_LENGTH` at 64
in `include/linux/soc/qcom/pdr.h`. So the message being rejected belongs to the
PDR service, and something is sending a 128-byte path against a 65-byte
definition.

The string does not come from anything this port serves: no path over 60
characters exists in `/usr/share/qcom/`, nor in the `.jsn` protection domain
descriptors under `/lib/firmware/qcom/sm8150/oneplus/hotdog/`. It comes from the
DSP side.

Identifying the exact message still needs tracing; what is established is the
limit, its single source, and the fact that 128 is twice 64 rather than an
arbitrary overrun.

## Separate from the known SLPI crash

[2026-08-10-slpi-sensor-dsp.md](2026-08-10-slpi-sensor-dsp.md) records a
different signature — `EX:sensor_process:0x1:frpck_0_0:0x58:PC=…` from an SMMU
context fault on stream `0x5a1`. This one is `EF:…:TMR_CLNT_1:…USER-PD DOG`,
a watchdog, with no SMMU fault anywhere near it.

## What it costs

With a dock attached the boot stalls on it long enough to look like a boot loop:
two crashes, no userspace, no network, and the phone appearing dead from the
host. It resumed on its own when the USB role changed. Without a dock the boot
completes and the cycle simply continues underneath.
