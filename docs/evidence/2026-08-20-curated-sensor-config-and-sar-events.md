# Curated sensor configuration and the first physical SSC event

Date: 2026-08-20

The full 65-file OxygenOS sensor directory is not a valid runtime selection.
It contains mutually exclusive alternatives for several products. Serving all
of them allowed unfitted drivers to win registry ownership and hid the fitted
parts. A 45-file board selection made from the handset's own OxygenOS 11 dump
removes those alternatives while preserving the Hotdog platform overlays.

That selection changes the result materially: the fitted SX9324 SAR sensor
registers with the Sensor Core and produces real events.

## Hardware proof

The Sensor Core publishes data type `sars` with SUID:

```
7335663959f5698867456bc70a6c70ca
```

A standard `SNS_STD_ON_CHANGE_CONFIG` subscription receives both the initial
configuration event and a sensor event:

```
event id=768 (config)
event id=769 (sensor) samples=0,95,11850,0,0 status=3
```

The event is delivered through QRTR service 400 by the running SLPI sensor PD;
it is not inferred from an I2C trace. `helpers/ssc-subscribe.py` contains the
small client used for this test and decodes only the standard event envelope.

## ALS/proximity controlled addition

Two stock-exact generic files were then added to the curated set:

```
alsps.json           2df496e3c4a0c10cf73692884f34f0039928ffd0f36804d81f6fe46594006f3e
msmnile_alsps.json   b81fbe2a8eca1e1e4c6f6560231fda07223a995203bc654647a401476accf085
```

This 47-file state creates the expected ALSPS registry groups and votes both
sensor rails. It does not publish `ambient_light`, `proximity` or `rgb`, and
the I2C ULog contains no transaction to the ALSPS address.

To test whether the working SAR driver monopolised QUP3, only the SX932x/SX9324
configuration and registry groups were removed. After a clean boot:

- no alternative physical SUID appeared;
- both sensor rails were still voted;
- the I2C ULog contained only QDI setup, with no transaction at all;
- `I2C_error` remained empty.

The original 47-file state was restored after the capture. Removing SAR frees
the bus but does not make ALSPS or MMC5603x submit a transfer, so bus capacity
or SAR ownership is not their blocker.

## Current per-family result

| Family | Transport | Result |
|---|---|---|
| SX9324 SAR | I2C QUP3, 0x28 | Working SUID and on-change events |
| LSM6DSM accel/gyro | SPI bus 2 | Blocked before probe: `spi_plat_init: npa_create_sync_client_ex failed` |
| TCS3701/ALSPS | I2C QUP3 | Registry and rail votes, no port transaction or SUID |
| MMC5603x magnetometer | I2C bus 1 | Registry present, no port transaction or SUID |

The next useful diagnostic boundary is inside the sensor PD. Platform ULogs
show transport setup and power votes, but the sensor drivers' detailed
`register_com_port` and discovery messages use Qualcomm diag. Further config
permutations would therefore be blind; the next work is reconstructing the
sensor-PD address map or exposing its diag stream, then comparing the working
SX9324 init path with LSM6DSM, ALSPS and MMC5603x.

