# The SAR reaches its chip; proximity never touches the bus

Date: 2026-08-23

A coredump taken with **only** the SAR and proximity subscribed — everything
else stopped, so the circular I2C buffer would hold their attempts and nothing
else. It separates two failures that had looked identical.

## What the bus shows

The I2C ring in this capture is not parseable by the ULog reader — one blob,
then `invalid message length 0`. The raw payload still carries transfer
descriptors, in the encoding the previous readable dump taught: a little-endian
word whose second byte is the slave address, `01 39 00 04` for `0x39`.

Scanning 676 bytes of retained payload:

| slave | descriptors | part |
| --- | ---: | --- |
| `0x30` | 3 | MMC5603 magnetometer — works |
| `0x28` | 2 | **SX9324 SAR** |
| `0x39` | 0 | TCS3701 — nothing subscribed to the ALS this time |

**The SAR driver does transact with its chip.** It opens the port, addresses
`0x28`, and gets answers with no entry in `I2C_error` anywhere near.

Proximity produced no traffic at all in the same window. That is weaker evidence
than the SAR's presence — a small retained window makes absence less conclusive
than presence — but it agrees with what the client sees.

## Two different failures, now with bus evidence

| | SAR | proximity |
| --- | --- | --- |
| published, has a SUID | yes | yes |
| request accepted and honoured | configuration event | ack only |
| I2C traffic to its chip | **yes, `0x28`** | none seen |
| emits a value | no | no |

The SAR is configured, talks to its chip, and does not report. Proximity is
never configured and never reaches the bus. A single explanation for both was
always going to be strained; this settles it.

## What was eliminated for the SAR

Each with the served registry read back afterwards to confirm the change took:

| tried | result |
| --- | --- |
| `is_dri` 1 → 0, so the driver polls instead of waiting on GPIO 96 | configured, silent |
| `res_idx` 2 → 0 | configured, silent |
| freeing GPIO 96 from Linux before the SLPI arms — see [the pin conflict](2026-08-23-linux-holds-the-sar-interrupt-pin.md) | configured, silent |
| requested rate swept 1, 2, 5, 10, 15, 20, 25, 50, 100 Hz | configuration event at every rate, no sample at any |

The rate sweep was aimed at `sensor_pressure ODR match error %d`, since the
driver derives its polling period from the requested ODR and can fail the match.
Every rate produced a configuration event and nothing else, so the ODR table is
not the gate.

Its registry is byte-identical to what OxygenOS wrote on this unit, and every
group name the 00083 image references — `sx9324_0_platform.config`,
`sx9324_0_platform.placement`, `sx9324_0.sar.config` and the `sx932x` triplet —
is served. Note the image never names the `_op` variants that the 00121 firmware
used; both sets are present in the registry and carry identical values.

## Where to look next

The driver's own strings name the reporting path and its failure modes:

```
sensor_instance_island.c:start_sensor_sar_polling_timer
sensor_instance_island.c:sar odr = %d
sensor_instance_island.c:sar timer_value = %u
sensor_instance_island.c:failed timer stream create rc = %d
sensor_instance.c:state->com_port_info.port_handle == NULL
sensor_instance.c:state->interrupt_data_stream == NULL
```

`failed timer stream create` is the candidate that fits: an instance that
configures, transacts with its chip, and then has no timer to poll on would
behave exactly as observed. Confirming it needs the diag channel this port has
no transport for — the same wall as proximity, reached from a different side.

## A note on hygiene

Six backup files created during these experiments were sitting **inside**
`sensors/registry/`, which the parser enumerates: two calibration backups, an
`is_dri` backup, a proximity offsets backup and one leftover from an earlier
session. They were moved to `/root/registry-sauvegardes-hors-arbre`. Keeping
working copies in a directory a parser walks is a way to create a fault that
looks like a driver bug.
