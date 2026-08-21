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
