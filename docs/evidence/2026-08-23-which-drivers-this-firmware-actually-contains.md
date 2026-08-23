# Which drivers this firmware actually contains

Date: 2026-08-23

The served config set describes a dozen sensor families. The SLPI image
contains five. Everything else is describing drivers that were never compiled
in.

## The inventory

Counting driver source-file names (`sns_<driver>_*.c`, which the firmware
embeds in full for its diag messages) as byte strings in `slpi.mbn`:

| driver | strings | role |
| --- | ---: | --- |
| `sns_lsm6dsm` | 175 | accelerometer, gyroscope, temperature |
| `sns_mmc5603x` | 166 | magnetometer |
| `sns_sx9324` / `sns_sx932x` | 86 each | SAR |
| `sns_alsps` | 59 | ALS / proximity / CCT combo |
| `sns_ak0991x` | 30 | magnetometer (alternate) |

and absent entirely:

```
tcs3701   stk2232   stk3331   stk2x2x   tmd2725   tmd3702   cm3526
lsm6dso   lsm6ds3c  bmi160    bmi26x    bu52053nvx  dps368   shtw2   bme680
```

## A correction to how this was first measured

The first version of this note counted **platform group names**
(`lsm6dsm_0_platform` and friends) rather than driver source files, and drew
the wrong conclusion twice:

- it reported `mmc5603x_0_platform` absent and inferred the magnetometer
  driver was not in the image. `sns_mmc5603x` is present with 166 strings;
  only the group name is built differently.
- it reported `stk2232_0_platform` present (2 occurrences) and counted
  `stk2232` as a compiled-in driver. `sns_stk2232` does not exist in the
  image at all.

Group-name presence is a poor proxy for driver presence, because several
drivers assemble their group names from immediates at run time rather than
storing them whole — which is exactly what `sns_alsps` does at `0xb21dbaf0`,
building `alsps_platform.als`, `.cct` and `.prox` byte by byte on the stack.
The source-file count above is the reliable measure.

What survives from the first version, confirmed both ways: **`tcs3701` is not
in this firmware.** Its twelve served registry groups and two config files do
nothing, the earlier "TCS3701-only" experiments were exercising a driver that
does not exist, and the ALS path on this device is `sns_alsps` alone —
consistent with the com-port signature in the coredump being `slave=0x46`,
the `alsps` address, three times over.

Also still true: removing `msmnile_sx9324_op.json` produced neither `sar` nor
`sars` because only the `_op` group names appear in the image —
`sx9324_0_platform` and `sx932x_0_platform` are absent, so the plain variants
were never going to take over.

## Where it leaves the accelerometer

Of the five hardware drivers actually present, two instantiate — `sns_alsps`
and `sns_sx9324` — and three do not: `sns_lsm6dsm`, `sns_mmc5603x` and
`sns_ak0991x`. That is the whole population, and it kills the "OnePlus
drivers versus Qualcomm drivers" reading: all five are in the same image,
named the same way, served configs the same way.

`lsm6dsm_0_platform` is the most referenced platform group in the image, 24
occurrences. The driver is present with more strings than any other, its
group is served with the values OxygenOS used on this unit, and it still
never instantiates.

## Practical consequence

Most of the sixty-six served config files are inert — they cost registry
parse time and clutter every comparison, but cannot cause anything. Future
experiments should work only from the five drivers above.

## Two more non-discriminators

**Island mode.** All five drivers ship `_island.c` translation units —
`lsm6dsm` four, `mmc5603x` three, `ak0991x` two, `sx9324` three, `alsps` two.
It is not what separates the two that instantiate from the three that do not.

**The bus — ~~for a structural reason~~ RETRACTED.** This section argued
that the bus could not gate instantiation, because a driver reads its
`bus_type` and `bus_instance` from the registry during `init`, after the
framework has created it. That was reasoning from an assumed ordering, and
it is wrong: moving the working SAR onto instance 2 or instance 1 makes it
stop registering entirely. See
[only bus instance 3 works](2026-08-23-only-bus-instance-3-works.md). The
LSM6DSM-on-instance-3 test still comes back negative, but that now means it
has a *second* fault, not that the bus is irrelevant.

That leaves the framework simply not calling three of the five drivers, for
a reason that is upstream of anything the registry can express.

## The firmware is the phone's own

Checked, because a version mismatch between the SLPI image and the OxygenOS
config/registry set would have explained a lot. It is not one.

`modem_b` is `/dev/sde31` (there is no `/dev/block/by-name` on this build).
Mounted read-only, its `image/` directory holds the split segments
`slpi.b00`–`slpi.b*`, and:

```
loaded    /lib/firmware/qcom/sm8150/oneplus/hotdog/slpi.mbn   SLPI.HY.2.2-00121
partition /mnt/modem_b/image/slpi.b04, .b08                   SLPI.HY.2.2-00121
b00 header identical to the first 756 bytes of the loaded mbn: yes
```

So the running firmware is the one this phone shipped with, and the drivers
that fail to instantiate are failing under their own vendor image.
