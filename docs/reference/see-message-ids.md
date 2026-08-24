# SEE message ids

Extracted from the protobuf descriptors embedded in
`/vendor/lib64/libsnsapi.so`, recovered from the OxygenOS 10.0.13 `super.img`.
These are the numbers a client needs and they are not guessable — several
services reuse the same value, so the pairing with the service matters.

## Requests

| id | message |
| ---: | --- |
| 1 | `SNS_STD_ATTR_REQ` |
| 2 | `SNS_STD_FLUSH_REQ` |
| 10 | `SNS_CLIENT_DISABLE_REQ` |
| 512 | `SNS_SUID_REQ`, `SNS_REGISTRY_READ_REQ`, `SNS_RESAMPLER_CONFIG`, `SNS_TIMER_SENSOR_CONFIG`, `SNS_INTERRUPT_REQ`, `SNS_ASYNC_COM_PORT_CONFIG` … |
| **513** | **`SNS_STD_SENSOR_CONFIG`** — streaming, carries a `sample_rate` float |
| **514** | **`SNS_STD_ON_CHANGE_CONFIG`** — on change, empty payload |
| 515 | `SNS_PHYSICAL_SENSOR_TEST_CONFIG` |
| 518 | `SNS_STD_EVENT_GATED_SENSOR_CONFIG` |
| 1808–1810 | OnePlus display: `DISPLAY_SETTING`, `DISPLAY_FRESH_RATE`, `DISPLAY_DC_MODE` |

## Events

Each sensor publishes under **its own** id. A client that accepts only 1025
silently discards most of them — which is exactly what happened here, and made
five working sensors look dead.

| id | event |
| ---: | --- |
| 128 | `SNS_STD_ATTR_EVENT` |
| 130 | `SNS_STD_ERROR_EVENT` |
| 768 | `SNS_STD_SENSOR_PHYSICAL_CONFIG_EVENT`, `SNS_SUID_EVENT` |
| **769** | **`SNS_PROXIMITY_EVENT`** |
| 770 | `SNS_HALL_EVENT` |
| 771 | `SNS_MOTION_DETECT_EVENT` |
| **772** | **`SNS_AMD_EVENT`**, `SNS_RMD_EVENT`, `SNS_SIG_MOTION_EVENT`, `SNS_CMC_EVENT`, `GATED_REQ_CONVERTED_TO_NON_GATED` |
| **774** | **`SNS_TILT_EVENT`** |
| **776** | **`SNS_DEVICE_ORIENT_EVENT`**, `SNS_RESAMPLER_CONFIG_EVENT` |
| 1022 | `SNS_CAL_EVENT` — calibration; its bias vector is usually zero and reads as a dead sensor if taken for a sample |
| 1024 | `SNS_INTERRUPT_EVENT`, `SNS_BRING_TO_EAR_EVENT`, `SNS_FACING_EVENT` … |
| **1025** | **`SNS_STD_SENSOR_EVENT`** — the generic one, accel/gyro/mag/light/temperature |
| **1026** | **`SNS_SAR_DATA`**, `SNS_PHYSICAL_SENSOR_TEST_EVENT` |
| 1027 | `SNS_POCKET_DATA` |
| 1028 | `SNS_PEDOMETER_STEP_EVENT`, `SNS_PICKUP_DATA` |
| 1029 | `SNS_OP_MOTION_DETECT_DATA` |
| 1031 | `SNS_PROXIMITY_EVENT_RECURRENT` |

## Indication layout

```
field 2 { 0x0d <id fixed32>  0x11 <timestamp fixed64>  0x1a <payload> }
payload: 0x0a <len> packed floats,  or  0x08 <varint>
```

## How to extract them again

`libsnsapi.so` carries serialised `FileDescriptorProto` data, so each enum value
appears as its name followed by `0x10` and a varint:

```sh
python3 - <<'PY'
import re
d = open("libsnsapi.so","rb").read()
for m in re.finditer(rb"SNS_[A-Z0-9_]+_MSGID_[A-Z0-9_]+", d):
    j = m.end()
    if j < len(d) and d[j] == 0x10:
        v = 0; s = 0; j += 1
        while True:
            c = d[j]; j += 1; v |= (c & 0x7f) << s; s += 7
            if not c & 0x80: break
        print("%-58s %5d" % (m.group(0).decode(), v))
PY
```

Recovering `libsnsapi.so` itself is described in
[the vendor recovery note](../evidence/2026-08-24-the-oxygenos-vendor-is-recoverable.md).

## Tried and negative

`518` on proximity returns the QMI acknowledgement and no indication, in three
payload forms. The control matters: **the working light sensor answers `518` the
same way**, so this driver does not accept the gated family at all, and the
negative says nothing about proximity specifically.
