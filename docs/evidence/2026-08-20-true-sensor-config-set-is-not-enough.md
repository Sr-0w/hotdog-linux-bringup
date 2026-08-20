# The true OxygenOS 11 sensor config set, and why it is not enough

Date: 2026-08-20

[The previous note](2026-08-19-sensor-config-set-is-from-the-wrong-oxygenos.md)
showed the sensor configuration we served came from OxygenOS 10.0.13 while the
phone shipped OxygenOS 11, and that the mismatch was corrupting the registry.
The real set has now been found and installed. The corruption is gone. No
sensor registers anyway.

## Where the real set was

Not in a 4 GB factory package. LineageOS extracts device blobs, and
`TheMuppets/proprietary_vendor_oneplus_hotdog` carries
`proprietary/vendor/etc/sensors/config/` for this exact device — 65 files,
about 100 KB.

Against the 61 we were serving it adds the 23 that were missing:

```
alsps.json              msmnile_alsps.json      default_sensors.json
devinfo_0.json          msmnile_lsm6dsm.json    mmc5603nj_0.json
msmnile_mmc5603nj.json  msmnile_sx932x_op.json  msmnile_sx9324_op.json
ak991x_dri_0.json       bmi160_0.json           lsm6ds3c_0.json
lsm6dsm_0_16g.json      msmnile_ak991x.json     msmnile_lsm6ds3c.json
msmnile_stk2x2x.json    msmnile_stk2x3x.json    msmnile_stk3331.json
sns_ccd_v3_1_walk.json  sns_fmv_legacy.json     stk2x2x_0.json
stk2x3x_0.json          stk3331_0.json
```

and drops 19 we had that describe other boards — `bmi26x_0.json`,
`msmnile_bmi26x_0.json`, `tmd3702.json`, `msmnile_tmd3702.json`,
`tmd2725`, `stk2232_0.json`, `lps22hh_0.json`, `msmnile_dps368_0.json`.

One of the drops matters on its own: the IMU's real platform file is
**`msmnile_lsm6dsm.json`**, not the `msmnile_lsm6dsm_0.json` we were serving.
Different file, different content.

## It fixes what it should fix

The DSP reads every new file, and the registry now agrees with the phone's own
`persist` copy on every field that used to be overwritten:

```
lsm6dsm_0_platform.config    bus_type=1 bus_instance=2 num_rail=2 irq_pull_type=3
alsps_platform.config        bus_instance=3 slave_config=70
sx932x_0_platform.config     slave_config=40 dri_irq_num=119
```

`num_rail` is back to 2, so the IMU is no longer denied its VDD rail;
`irq_pull_type` is back to 3; the SAR is back at 0x28 with DRI 119.

## And it changes nothing about the symptom

```
accel  gyro  mag  proximity  ambient_light  rgb  sar  sensor_temperature
amd    tilt
                             -- all still "no SUID"
```

So the wrong config set was a real defect and is now repaired, but it was not
the reason the sensors are dead. Whatever blocks the hardware drivers sits
below the configuration layer.
