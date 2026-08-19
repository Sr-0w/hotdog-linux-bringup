# Which sensors this board actually has, from its own calibration data

Date: 2026-08-19

The registry we serve came from the phone's `persist` partition, so its
OnePlus-specific entries are ground truth for this board. The `devinfo` group
names, for each sensor slot, the registry path where the factory calibration
lives:

```
devinfo.gsensor -> lsm6dsm_0_platform.accel.fac_cal.bias
devinfo.gyro    -> lsm6dsm_0_platform.gyro.fac_cal.bias
devinfo.als     -> alsps_platform.als.fac_cal
devinfo.ps      -> alsps_platform.prox.fac_cal
devinfo.rgb     -> alsps_platform.cct.fac_cal
```

So the OnePlus 7T Pro carries an **LSM6DSM** for accelerometer and gyroscope,
and one **`alsps`** part providing ambient light, proximity and RGB. Everything
else in the registry — `bmi26x`, `bmi160`, `tmd3702`, `tmd2725`, `tcs3701`,
`stk2232`, `ak0991x`, `lps22hh` — is a decoy for other boards. The firmware
agrees: it contains `sns_lsm6dsm`, `sns_alsps`, `sns_mmc5603x`, `sns_sx932x`
and `sns_sx9324`, and no driver for any of the decoys.

Their buses, from the registry:

| slot | driver | bus | instance | address | speed | DRI |
|---|---|---|---|---|---|---|
| accel + gyro | `lsm6dsm` | SPI | 2 | CS0 | 9600 kHz | 132 |
| ALS + prox + RGB | `alsps` | I2C | 3 | 0x46 | 400 kHz | 120 |
| SAR | `sx932x` | I2C | 3 | 0x2c | 400 kHz | 87 |
| SAR | `sx9324` | I2C | 3 | 0x28 | 400 kHz | — |

Note `alsps_platform.cct.fac_cal`: the part has a colour-temperature channel, so
a complete `alsps` config declares `.als`, `.prox` **and** `.cct`.

## What the DSP puts on the wire, and why

Read with `scripts/slpi/slpi-ulog-dump.py` over a full boot:

```
0x28  write x2, read x1        canal 1 / canal 0
0x2c  write x2, read x2        canal 1 / canal 0
close core 3
```

Only the two SAR addresses, only on QUP core 3, six `ERROR nack` and twelve
`bus_iface_callback : ERROR DMA EVT OTHER during data phase`. Nothing for the
ALS at 0x46, nothing for the magnetometer, and not one byte of SPI.

The SAR is the only family for which we serve a config JSON *and* the firmware
holds a driver, which is why it is the only family probed.

## Serving the config is necessary but not sufficient

`alsps.json` and `msmnile_alsps.json` are absent from the OxygenOS 10.0.13 set
we serve. They were synthesised from the phone's own registry values and
installed (`firmware/sensors/config/`). After a reboot the DSP reads both:

```
2 config/alsps.json
2 config/msmnile_alsps.json
```

and yet:

- the SUID lookup still answers "no SUID" for `ambient_light` and `proximity`;
- a fresh coredump shows 0x46 still never reaches the wire — the probed set is
  unchanged at 0x28 and 0x2c.

So parsing a platform config does not by itself instantiate a driver. Something
else gates instantiation, and finding it is the next step. The synthesised
files are kept: the values are the phone's own and they will be needed
regardless.

## Also settled

`spi_plat_init` aborting is not the reason the IMU is dead — or at least not
the whole reason. Its last act is a DDR bandwidth vote for ICB masters
`BLSP_1` and `BLSP_2`, which exist in no SM8150 topology and appear nowhere in
any loaded segment; `icb_info`, the DevCfg property that could supply another
topology, is a 4-byte BSS variable that no code in the image writes. The
failure is therefore identical under OxygenOS. On failure the function stores a
null bandwidth handle and returns, so `spi_open` is not blocked — and the SPI
log holds exactly one record, meaning no sensor ever called it.

## The rail request is not the gate either

The `alsps` driver does run. The file service shows it reading its whole
registry group, three times over:

```
3 alsps          3 alsps.als          3 alsps.als.config
3 alsps_platform 3 alsps.prox         3 alsps.prox.config
3 alsps_platform.config
2 alsps_platform.als.fac_cal          2 alsps_platform.prox.fac_cal
```

It simply never opens its bus. The obvious difference against the SAR, which
does reach the wire, is the rail request: the SAR asks for two rails that both
resolve to `/pmic/client/sensor_vddio`, while the ALS asks additionally for
`/pmic/client/sensor_vdd`, which appears nowhere in the PMIC log.

Tested by rewriting the synthesised config to `num_rail=1`,
`rail_on_state=1`, `sensor_vddio` only — the SAR's shape — and rebooting. The
probed set is unchanged: 0x28 and 0x2c, nothing at 0x46. The rail request is
not what gates bus access, and the config has been restored to the values the
phone's own registry carries.
