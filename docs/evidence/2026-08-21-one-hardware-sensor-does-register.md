# Correction: one hardware sensor does register, and it is OnePlus' own

Date: 2026-08-21

This corrects a claim repeated throughout the sensor investigation — that no
hardware sensor driver publishes a SUID. One does.

## The mistake

Every survey queried the SEE standard data type `sar`, singular. The type this
firmware publishes is **`sars`**, plural, as listed in the phone's own
`persist/sensors/sensors_list.txt`. Asking for the right name:

```
data-type 'sars': 7335663959f5698867456bc70a6c70ca
data-type 'sars': 7335663959f5698867456bc70a6c70ca      (reproducible)
```

`sensor_logger` also registers, with the placeholder SUID
`11111111111111111111111111111111`.

Everything else is still absent — `accel`, `gyro`, `mag`, `proximity`,
`ambient_light`, `rgb`, `sensor_temperature`, `gravity`, `game_rv`,
`geomag_rv`, `rotv`, `fmv`, `motion_detect`, `free_fall`, `sig_motion`,
`pedometer` — and so are the other OnePlus types: `wise_light`, `lux_aod`,
`psmd`, `camera_protect`, `amd_oplus`, `oplus_activity_recognition`,
`pick_up_motion`, and `devinfo` in any spelling.

## Why it matters

The chain is not systemically broken. For `sx932x_op`, registry lookup, com
port acquisition, hardware probe and SUID publication all complete on this
kernel, with this firmware, over this bus. That rules out a whole class of
explanations that the earlier framing supported — the framework, the com port
layer, the registry service and the QUP path all demonstrably work for at
least one physical sensor.

It also fits the wire evidence, which always showed the SAR addresses being
driven and nothing else: 0x28 and 0x2c on qup-3. Those transactions belong to
the driver that goes on to publish.

## The question this leaves

Not "why does nothing work" but "why does OnePlus' SAR driver complete while
the stock Qualcomm ones — `lsm6dsm`, `alsps`, `mmc5603x` — never open a port".

One visible difference: the SAR is the only family whose registry carries an
OnePlus `_op` platform group, `sx932x_op_0_platform` and
`sx9324_op_0_platform`, alongside the stock one. The IMU, the ALS and the
magnetometer have stock groups only. Whether this firmware expects an `_op`
group for those too, and simply declines the ones it finds, is the next thing
to test — and it is testable from the file service, without a flash.

## A regression I caused, and repaired

Two pieces of state had degraded during the experiments above, both now
restored, and both worth recording because the second cannot be recreated from
any file we ship.

**The served config set had fallen to 48 files** of the 65 the LineageOS blob
set carries. Missing were `devinfo_0.json`, `msmnile_sx932x.json`,
`msmnile_sx932x_op.json`, and the `ak991x`, `stk*` and `lsm6ds3c` families —
casualties of moving families aside and back during the capacity tests.
Redeployed from `firmware/sensors/config/`, verified at 65. One file on the
phone is not ours and was left alone:
`msmnile_power_0.json.pre-island-off-20260820`.

**The factory `devinfo` group had been destroyed.** The phone's `persist`
carries five entries the sensors depend on for their calibration paths:

```
devinfo.als      -> alsps_platform.als.fac_cal
devinfo.gsensor  -> lsm6dsm_0_platform.accel.fac_cal.bias
devinfo.gyro     -> lsm6dsm_0_platform.gyro.fac_cal.bias
devinfo.ps       -> alsps_platform.prox.fac_cal
devinfo.rgb      -> alsps_platform.cct.fac_cal
```

Letting the DSP rewrite the registry from the config files erased them, and
**no config file restores them**. `devinfo_0.json` looks like the candidate but
is not: its gate excludes this SoC —

```json
"soc_id": ["291", "246", "305", "321", "336", "341", "360"]     /* no 339 */
```

— and the group it would build is `oppo_devinfo`, pointing at `tsl2540`, a
different part entirely. The real `devinfo` is factory data, and `persist` is
its only source.

Restored from `persist`: 439 registry entries, the five `devinfo` entries back
and surviving a reboot, config set complete at 65.

## And the result is unchanged

```
sars           ENREGISTRE  7335663959f5698867456bc70a6c70ca
accel  gyro  mag  proximity  ambient_light  rgb        -
```

So neither the incomplete config set nor the missing `devinfo` group explains
why the stock drivers stay silent. Both are now correct, and the difference
between `sx932x_op` and the rest is still unaccounted for.

Worth carrying forward: **the registry must be restored from `persist` after
any experiment that lets the DSP rewrite it**, or factory-only groups are lost
for good.

## Exactly which registry groups the firmware asks for

String-scanning every loaded segment for platform group names gives the
complete list this image can use:

```
ak0991x_0_platform          alsps_platform            lsm6dsm_0_platform
stk2232_0_platform          sx9324_op_0_platform      sx932x_op_0_platform
sns_device_orient_platform  sns_fmv_platform          sns_rotv_platform
```

and the per-sensor configuration groups:

```
alsps.als.config      alsps.prox.config     sx932x_0.sar.config
lsm6dsm_0.accel.config  lsm6dsm_0.gyro.config
lsm6dsm_0.md.config     lsm6dsm_0.temp.config
```

Three things follow.

**The SAR mixes conventions.** Its platform group is the OnePlus `_op` variant
and the firmware never references `sx932x_0_platform` at all, while its sensor
group is the plain `sx932x_0.sar.config`. So "the working one uses `_op`" is
only half true, and there is no `_op` platform group for the IMU or the ALS to
be missing — the firmware does not ask for one.

**`mmc5603x_0_platform` is never referenced.** The registry carries it and the
config set builds it, but no code in this image reads it. Whatever drives the
magnetometer on this board, it is not through that group, which also explains
why the magnetometer was never going to appear no matter what we served it.

**The IMU and ALS groups are exactly the ones the firmware wants**, and both
are present in the registry with the right sub-groups. So the failure is not a
missing or misnamed group.

The `owner` field differs between them — `sns_sx932x` for the SAR against
`lsm6dsm` for the IMU — but that comes straight from the vendor's own
`msmnile_lsm6dsm.json`, so it is a naming convention rather than a defect.

## The rail request is not it either, tested against the control

With `sars` as a working control on the same bus, the one clean configuration
asymmetry between it and the two failing drivers is the rail request:

```
sx932x_op (works)   rail_on_state=1  vdd_rail=/pmic/client/sensor_vddio
alsps     (fails)   rail_on_state=2  vdd_rail=/pmic/client/sensor_vdd
lsm6dsm   (fails)   rail_on_state=2  vdd_rail=/pmic/client/sensor_vdd
```

Both failing drivers ask for a second, real rail; the working one points both
of its rails at `sensor_vddio`. The PMIC log has never shown activity for any
rail but `ldoc8`, which is `sensor_vddio`, so a driver blocking on
`sensor_vdd` would have been a single explanation covering both.

Aligned `alsps` and `lsm6dsm` on the SAR's shape — `rail_on_state=1`,
`vdd_rail` pointed at `sensor_vddio` — deleted the two registry entries so they
would be rebuilt, and rebooted. The registry took the change:

```
alsps_platform.config      rail_on_state=1 vdd_rail=/pmic/client/sensor_vddio
lsm6dsm_0_platform.config  rail_on_state=1 vdd_rail=/pmic/client/sensor_vddio
```

and nothing else moved: `sars` still registers, `accel`, `gyro`, `proximity`,
`ambient_light`, `rgb` and `mag` still do not. Unlike the earlier version of
this test, this one ran with the complete config set, the factory registry and
a known-good control, so it settles the question. The vendor values have been
restored.
