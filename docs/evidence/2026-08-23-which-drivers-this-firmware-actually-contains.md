# Which drivers this firmware actually contains

Date: 2026-08-23

The served config set has 66 files describing a dozen sensor families. The
SLPI image contains six. Everything else is describing drivers that were
never compiled in.

## The inventory

A platform group name only matters if the firmware asks for it. Counting
occurrences of each name as a byte string in `slpi.mbn`:

| platform group | occurrences |
| --- | ---: |
| `lsm6dsm_0_platform` | 24 |
| `ak0991x_0_platform` | 8 |
| `alsps_platform` | 8 |
| `sx9324_op_0_platform` | 6 |
| `sx932x_op_0_platform` | 6 |
| `stk2232_0_platform` | 2 |

and absent entirely:

```
sx9324_0_platform      sx932x_0_platform      tcs3701_platform
mmc5603x_0_platform    bmi26x_0_platform      bmi160_0_platform
lsm6dso_0_platform     lsm6ds3c_0_platform    stk2x2x_0_platform
stk2x3x_0_platform     stk3331_0_platform     tmd2725_0_platform
tmd3702_platform       cm3526_0_platform      bu52053nvx_0_platform
ifx_dps368_0_platform  shtw2_0_platform       bme680_0_platform
```

So this build's real sensor complement is: the LSM6DSM IMU, an AK0991x
magnetometer, the OnePlus `alsps` ALS/proximity combo, and the Semtech SAR in
its two OnePlus variants — plus `stk2232`.

## What that corrects

**`tcs3701_platform` is not in the firmware at all.** Serving its twelve
registry groups and two config files achieves nothing, and the earlier
"TCS3701-only" experiments were exercising a driver that does not exist in
this image. The ALS path on this device is `sns_alsps` and only `sns_alsps` —
which is consistent with the com-port signature in the coredump being
`slave=0x46`, the `alsps` address, three times over.

It also explains a result that looked strange:
`msmnile_sx9324_op.json` was moved aside to see whether the plain
`sx9324_0_platform` variant would take over. Neither `sar` nor `sars`
appeared. Of course not — `sx9324_0_platform` is not a name this firmware
ever looks up. Only the `_op` variants exist.

## Where it leaves the accelerometer

`lsm6dsm_0_platform` is the **most referenced** platform group in the image,
24 occurrences, more than any other. The driver is present, it is central,
and its group is served with the values OxygenOS used on this unit. It still
never instantiates, while `alsps` and `sx9324_op_0` — two of the other five —
do.

So the split is not "OnePlus drivers versus Qualcomm drivers", which was the
previous reading and does not survive this inventory: `lsm6dsm_0` and
`ak0991x_0` are named by the same firmware in the same way as `alsps_platform`
and `sx9324_op_0_platform`. Three of the six instantiate nothing, two
instantiate, and the difference between those groups is not in their names,
their bus, their config values, or their presence.

## Practical consequence

Sixty of the sixty-six served config files are inert. They cost registry
parse time and clutter every comparison, but they cannot be the cause of
anything. Any future experiment should work from the six names above.
