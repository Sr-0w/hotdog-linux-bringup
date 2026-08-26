# The IMU orientation we must serve is the transpose of the phone's own

Date: 2026-08-26

The display followed the phone but sat 90° off: bottom on the right. The
accelerometer worked, so this was never a driver fault — only an axis mapping.

Follows
[2026-08-19-sensor-config-set-is-from-the-wrong-oxygenos.md](2026-08-19-sensor-config-set-is-from-the-wrong-oxygenos.md),
and is the same defect surfacing in a new place.

## The real part had no orientation at all

The accelerometer is an LSM6DSM driven by the sensor DSP, not by IIO, so its
orientation comes from the SEE configuration rather than from a kernel mount
matrix. `msmnile_lsm6dsm.json` carried `.config`, `.accel`, `.gyro`, `.temp`,
`.md`, `.ff`, `.hs` and `.placement` — and no `.orient`. The part therefore had
no orientation and SEE fell back to identity.

Meanwhile the only `.orient` anywhere in the served set belonged to
`msmnile_lsm6ds3c.json`, a different IMU that this phone's firmware does not
drive at all:

```
lsm6ds3c   x=+y  y=+x  z=-z      served, wrong part
lsm6dsm    (absent)               the part the firmware actually drives
```

That is the OxygenOS 10.0.13 set showing through again on a phone running
OxygenOS 11.

## The authentic value, read rather than guessed

`persist` was never touched by the postmarketOS install. Mounted read-only it
still holds the phone's original OxygenOS 11 registry:

```
lsm6dsm_0_platform.orient   x=+y  y=-x  z=+z
lsm6ds3c_0_platform.orient  x=+y  y=+x  z=-z
```

`+y/-x/+z` is a 90° rotation about z. Identity measured against that rotation is
exactly the 90° error observed, which made the diagnosis look complete.

## But transcribing it verbatim is wrong

Serving `+y/-x/+z` moved the error from 90° to **180°**, upside down. The applied
rotation had added 90° instead of removing it. With `E` the observed error and
`θ` the rotation the configuration applies, the two measurements give `E = 90° +
θ`, so the entry we need is `θ = −90°` — the inverse, which for a rotation
matrix is its transpose:

```
x=-y  y=+x  z=+z          confirmed: AccelerometerOrientation "normal",
                          rotation follows the phone in the right direction
```

The registry value is authentic. SEE and our stack simply do not read it in the
same direction: one names, for each device axis, the sensor axis that feeds it,
and the other states the opposite. Copying the phone's registry into a config
file therefore yields a 180° error, and this is the trap worth remembering —
nothing about the value looks wrong, and both forms are proper rotations.

## Scope

Orientation is how the part is soldered to the board, so it is a board constant,
identical across every HD1913. Unlike `.fac_cal` correction matrices it carries
nothing specific to this unit and is safe to package.

Applied in `firmware/sensors/config/msmnile_lsm6dsm.json` and shipped through
`hotdog-sensor-config`.
