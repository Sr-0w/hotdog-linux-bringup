# The sensor config set we serve is from the wrong OxygenOS

Date: 2026-08-19

Follows [2026-08-19-sensor-core-registers-no-driver.md](2026-08-19-sensor-core-registers-no-driver.md),
which established that the SEE framework is healthy and that no *hardware*
sensor driver registers. This is why.

## Two halves from two different releases

The firmware is the phone's own, pulled from `modem_b`. The phone shipped:

```
/dev/disk/by-partlabel/opproduct_b  ->  build.prop
  ro.build.version.ota = OnePlus7TProOxygen_13.W.24_GLO_0240_2103170222
  ro.display.series    = OnePlus 7TPro
```

which is OxygenOS 11, built 2021-03-17. The sensor configuration we serve under
`/usr/share/qcom/sensors/` comes from the OxygenOS **10.0.13** extract, and is
owned by no package:

```
apk info --who-owns /usr/share/qcom/sensors/config/lsm6dsm_0.json
  ERROR: Could not find owner package
```

`/vendor/etc/sensors/config` in the 10.0.13 image holds 61 files. Ours holds the
same 61, name for name. But the registry we serve — which came from the phone's
own `persist`, and carries OnePlus-specific entries such as
`sx932x_op_0_platform` — records **94** config files. Those 33 extra files are
the OxygenOS 11 set.

## The halves do not describe the same sensors

Driver names built into the firmware:

```
sns_lsm6dsm      sns_mmc5603x     sns_sx932x     sns_sx9324     sns_alsps
```

and, in live DSP memory, OnePlus' own code:

```
oplus_alsps_island.c:s_head did not init
sx932x_op_0_platform.config
sx9324_op_0_platform.config
```

Names the firmware does **not** contain, checked by string search over every
loaded segment:

```
bmi26x  0    bmi160  0    tmd3702  0    tmd2725  0
```

Yet `bmi26x_0.json`, `msmnile_bmi26x_0.json`, `tmd3702.json`, `tcs3701.json`,
`stk2232_0.json`, `lps22hh_0.json` and `msmnile_dps368_0.json` are all in the
set we serve. They configure parts this firmware cannot drive.

Missing on our side, and referenced by the registry:

```
alsps.json              msmnile_alsps.json
msmnile_sx932x_op.json  msmnile_sx9324_op.json
mmc5603nj_0.json        msmnile_mmc5603nj.json
default_sensors.json    devinfo_0.json          msmnile_lsm6dsm.json
```

`alsps` is the ALS/proximity driver the firmware actually has, and its config is
absent. The `_op` files are OnePlus' own SAR variants.

## Which matches what the DSP does

Decoding the GPI descriptors in the DSP's `I2C` buffer with the downstream
layout (`MSM_GPI_I2C_GO_TRE_DWORD0(flags, slave, opcode)` from
`include/linux/msm_gpi.h`):

```
canal 0  slave 0x28  read      canal 1  slave 0x28  write
canal 0  slave 0x2c  read      canal 1  slave 0x2c  write
```

0x28 and 0x2c are the Semtech SAR addresses. **The only family where our config
set and the firmware's drivers overlap is the SAR**, and it is the only family
the DSP ever puts on the wire. It then answers `ERROR nack`, which is what the
OxygenOS 10 addressing gets on a board that wants the `_op` variant.

Nothing is probed for the IMU, the magnetometer or the ALS.

## Sanity checks that came back clean

So these are not the cause and need not be revisited:

- **Platform gate.** Every config carries `"config":{"hw_platform":[...],
  "soc_id":[...]}`. We serve `hw_platform=MTP`, `soc_id=339`, which satisfies
  the gates on `msmnile_lsm6dsm_0.json`, `msmnile_mmc5603x_0.json` and the SAR
  configs alike.
- **DSP libraries.** `dspso.bin/sdsp` from OxygenOS holds 18 files; we serve 17,
  missing only `chre_drv_bt.so`, which is the context-hub Bluetooth driver.
- **The framework.** `registry` and `timer` both return SUIDs, so SEE itself
  registers sensors correctly.
- **Rails.** `pm_xo_driver_fcn: Done Rsrc=/pmic/client/xo` shows the DSP's PMIC
  client working; ldo7 and ldo8 are up at 2856 mV and 1800 mV.

## Where the missing files have to come from

The phone's `super` partition was reused by the postmarketOS install and now
reads as zeros, so the OxygenOS 11 `vendor` is no longer on the device. The
`persist`, `opproduct`, `op1`, `op2` and `dsp_b` partitions survive, but none
carries `/etc/sensors`. The set therefore has to come from an OxygenOS 11
package for HD1913 — build `11.W.24` or near it.

## Proof, and a partial repair

The phone's `persist` partition was never touched by the postmarketOS install.
Mounted read-only it still holds the original OxygenOS 11 registry, 438
entries. Comparing it against the copy we serve — which the DSP rewrites from
our config files at every boot — 428 entries match and **ten differ**:

```
ak0991x_0_platform.config       ak0991x_0_platform.orient
lsm6dsm_0_platform.config       mmc5603x_0_platform.config
mmc5603x_0_platform.mag.fac_cal.corr_mat
sns_fmv_platform.config         sns_gyro_cal_config
sns_reg_config                  sx932x_0_platform.config
tcs3701_platform.als.fac_cal
```

Every one of them is a sensor the board actually has, and in each case the
served value is the OxygenOS 10.0.13 one overwriting the phone's own:

| entry | field | phone | overwritten with |
|---|---|---|---|
| `lsm6dsm_0_platform` | `irq_pull_type` | 3 | 2 |
| | `num_rail` | 2 | 1 |
| | `rail_on_state` | 2 | 1 |
| `sx932x_0_platform` | `slave_config` | **40 (0x28)** | **44 (0x2c)** |
| | `dri_irq_num` | 119 | 87 |
| | `irq_pull_type` | 0 | 3 |
| | `num_rail` | 1 | 2 |
| `mmc5603x_0_platform` | `rail_on_state` | 2 | 1 |

The SAR line is the clearest: the phone puts that part at **0x28**, our config
set moved it to 0x2c, and 0x2c is one of the two addresses the DSP was seen
NACKing. `num_rail=1` on the IMU likewise denies the LSM6DSM its VDD rail.

`msmnile_lsm6dsm_0.json`, `msmnile_sx932x.json` and `msmnile_mmc5603x_0.json`
now carry the phone's values (`firmware/sensors/config/`), and after a reboot
the registry keeps them: `sx932x slave_config=40`, `lsm6dsm num_rail=2`. The
corruption is gone.

Timestamps are not a way around this. The parser records each config file's
mtime in `sns_reg_config` as its version, but it reparses regardless — setting
every config's mtime to the recorded `1230768000` changed nothing. The values
have to be right in the JSON itself.

No sensor registers yet: `accel`, `gyro`, `proximity`, `ambient_light`, `sar`
and `mag` all still answer "no SUID", and the wire still shows only 0x28 and
0x2c on qup-3. So the corrupted registry was a real defect but not the last
one.
