# No sensor driver registers, and the arbiter was not to blame

Date: 2026-08-19

This corrects [2026-08-19-icb-info-devcfg.md](2026-08-19-icb-info-devcfg.md),
which concluded that the sensor bus dies because the ICB arbiter's master table
holds a single entry. The arbiter works. The measurement below replaces the
inference.

## The measurement that should have come first

The sensor core publishes QMI service 400, and `helpers/ssc-client.py` speaks
it. Asking the SUID lookup for each data type:

```
service 400, node 9, port 12          -- registered
accel         -> result ok, no SUID
gyro          -> result ok, no SUID
mag           -> result ok, no SUID
proximity     -> result ok, no SUID
ambient_light -> result ok, no SUID
```

The framework is alive and answers correctly. **Not one sensor driver has
registered.** That is the fact to explain, and it is much narrower than "the
buses are broken".

## The arbiter is not broken

`ICB Arb Log`, resolved against the firmware from `/mnt/modem_b/image`:

```
ts=190848968  Issue Pair Request (MID: 131, SID: 143) (Ib: 0x1)
ts=190963256  Issue Pair Request (MID: 131, SID: 143) (Ib: 0x989680)
ts=191105370  Issue Pair Request (MID: 131, SID: 143) (Ib: 0xb2d05e00)
ts=191269581  Issue Pair Request (MID: 131, SID: 143) (Ib: 0x0)
```

Masters 131, 112, 76, 180 and 52 all resolve, and real bandwidth is voted —
10 MB/s, then 3 GB/s, then released. An arbiter with no usable topology does
not do that.

## What actually fails, and why it is expected

Two NPA clients are refused, and only those two:

```
npa_create_sync_client ("/icb/arbiter") ("I2C_QUP_DDR") (NPA_CLIENT_VECTOR)
 FAILED npa_new_client "I2C_QUP_DDR": resource "/icb/arbiter" ... (error: 4)
npa_create_sync_client ("/icb/arbiter") ("SPI_QUP_DDR") (NPA_CLIENT_VECTOR)
 FAILED npa_new_client "SPI_QUP_DDR": resource "/icb/arbiter" ... (error: 4)
spi_plat_init: npa_create_sync_client_ex failed
```

The bandwidth vectors are static in the image and name masters 41 and 39.
Downstream names them:

```
include/dt-bindings/msm/msm-bus-ids.h
  #define ICBID_MASTER_BLSP_2 39
  #define ICBID_MASTER_BLSP_1 41
```

BLSP is the pre-SM8150 low-speed peripheral block. The SM8150 has QUPs. A
search of every loaded segment for a route node keyed on master 41 or 39 finds
**none** — while the same search finds master 131 (`SENSORS_PROC`) exactly once,
so the search is sound.

The masters do not exist in this firmware's topology, nothing in the image
writes the `icb_info` pointer that would supply another one, and BSS is zeroed
at load. So this failure is identical under OxygenOS: `spi_plat_init` fails
there too. It is a legacy path, not our regression.

## The route lookup, for the record

Reverse engineered from `0xb016688c` and `0xb0166ac4`. The second level is a
binary search tree over a 64-bit key:

```
node +0x00  key = (master << 32) | slave      64-bit, ordered on the whole word
     +0x08  route object
     +0x0c  left child
     +0x10  right child
```

and the first level is a bounds-checked array: `if (count <= master) return
NULL; rec = table[master]`. The master record holds `root` at `+0x08` and
`count` at `+0x0c`.

## Two more benign findings, so they are not chased again

**`Invalid Rsrc=/pm/ldoc8/mode` and `/pm/ldoc8/mV`** are not errors. Downstream
declares that rail as enable-only:

```
sm8150-regulator.dtsi
  rpmh-regulator-ldoc8 {
      compatible = "qcom,rpmh-xob-regulator";     /* XOB: on/off, no mode, no mV */
      qcom,resource-name = "ldoc8";
      L8C: pm8150l_l8 { regulator-min-microvolt = <1800000>; ... };
```

An XOB resource has no mode and no voltage sub-resource, so asking for them is
invalid by construction. The DSP logs it at `Info:` level, not `ERROR`.

The rails are also physically up, held by the AP-side hall sensors which share
them:

```
ldo8   use 2   1800mV    consumers 1-000c-vio, 1-000d-vio
ldo7   use 2   2856mV    consumers 1-000c-vdd, 1-000d-vdd
```

so the sensors are powered. That theory is closed.

**The DSP library set is correct.** `dspso.bin` from OxygenOS 10.0.13 carries 18
files under `/sdsp`; we serve 17. The only one missing is `chre_drv_bt.so`,
which is the context-hub Bluetooth driver, not a sensor driver.

## The sensor map, from the registry we serve

The registry is a superset covering many possible parts. The firmware decides
which matter, and it contains `sns_lsm6dsm`, `sns_mmc5603x`, `sns_sx932x`,
`sns_sx9324` and `sns_alsps` — and no `bmi26x`, `bmi160`, `tmd3702` or
`tmd2725`, whose registry entries are therefore decoys.

| sensor | driver | bus | instance | address | speed | DRI |
|---|---|---|---|---|---|---|
| accel + gyro | `lsm6dsm` | SPI | 2 | CS0 | 9600 kHz | 132 |
| magnetometer | `mmc5603x` | I2C | 1 | 0x30 | 400 kHz | — |
| ALS + proximity | `alsps` | I2C | 3 | 0x46 | 400 kHz | 120 |

`bus_type` is 0 for I2C and 1 for SPI. All three sensors draw
`/pmic/client/sensor_vddio`, and the IMU and ALS also `/pmic/client/sensor_vdd`.

This is why the accelerometer and gyroscope cannot come up while
`spi_plat_init` aborts: the IMU is the one part behind SPI.

## Open, and where to look next

The I2C sensors are not blocked by SPI and still do not register. The I2C
buffer shows live GSI traffic and `I2C_error` shows `ERROR nack` with
`bus_iface_callback : ERROR DMA EVT OTHER during data phase`, so the controller
runs and the parts do not answer.

One host-visible difference is worth pursuing:

```
ADSPPM  ClkRgm_SetClock: Failed to set freq 122880000 for scc_noc_bus_clk. Capped freq=96000000
ADSPPM  ClkRgm_SetClock: Failed to set freq 204800000 for scc_noc_bus_clk. Capped freq=96000000
```

The SSC NOC bus clock is capped at 96 MHz against 122.88 and 204.8 MHz
requested. The SSC's peripherals hang off that NOC.
