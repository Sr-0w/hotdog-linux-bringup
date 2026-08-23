# The SLPI firmware version was the cause — 7 of 9 sensors now register

Date: 2026-08-23

## The change

```
before  /lib/firmware/.../slpi.mbn   SLPI.HY.2.2-00121   sha256 6e80f8a6…
after   from OxygenOS 10.0.13        SLPI.HY.2.2-00083   sha256 1b17eb7b…
```

One file replaced, one reboot. Nothing else touched.

## The result

| type | before | after |
| --- | --- | --- |
| `accel` | — | `1fbb6afc01727ea69a418d19f8d7ba44` |
| `gyro` | — | `97d3c48969f972a0b9418a10491511c1` |
| `mag` | — | `64bba517c99048b0ac450869b71d795b` |
| `proximity` | — | `5f5f584f525031303733534354736d61` |
| `ambient_light` | — | `5f5f5f534c4131303733534354736d61` |
| `sensor_temperature` | — | `973615c0c0808fa3af4002dc9cb83279` |
| `sars` | works | works |

**7 of 9 hardware sensors**, against 1 before. Only `rgb` and `cct` — the
ALS colour channels — are still absent.

The whole derived tail came with them. Of 32 SEE data types polled, **24
publish** where 4 did before: `gravity`, `game_rv`, `rotv`, `geomag_rv`,
`fmv`, `amd`, `rmd`, `tilt`, `device_orient`, `pedometer`, `motion_detect`,
`gyro_cal`, `mag_cal`, `facing`, `basic_gestures`, `bring_to_ear`, `dpc`.

## It streams

The ambient light sensor delivers events every ~5 ms whose float payload
changes sample to sample — live channel readings, not a static config echo:

```
1033.46   858.0   185.0   589.0  …   83.7
1028.10   832.0   180.0   588.0  …   83.2
1023.97   837.0   180.0   600.0  …   82.9
```

## Why this closes the investigation's open question

`accel` and `gyro` publish exactly the two SUIDs recovered weeks-deep into
the disassembly from the LSM6DSM descriptor table — `1fbb6afc…` at
`0x97aa401c` and `97d3c489…` at `0x97aa4044`. The driver that "never
instantiates" instantiates fine under 00083. So the descriptors, the
registration path and the drivers were all correct; the 00121 build simply
does not bring these drivers up on this board.

That also explains, in hindsight, every negative result: the registry served
verbatim from OxygenOS changed nothing, the bus was cleared, the transport
was cleared, the hardware was cleared — because none of them were the
variable. The variable was the firmware image, and it was never suspected
because `modem_b` on this phone carries 00121 and that check was read as
"we are running the phone's own firmware".

The phone's `modem_b` does carry 00121. The registry backup at
`/root/registry-backup-oos10` is from OxygenOS 10.0.13, which shipped 00083.
The partition had been updated by an OTA past the build the sensor
configuration was written for.

## What remains

- `rgb` / `cct`: the ALS colour channels. `alsps_platform.config` now carries
  `slave_config` 57 (`0x39`), the address measured earlier as the one where a
  device answers; whether the colour path needs more is untested.
- The streaming client only speaks `SNS_STD_ON_CHANGE_CONFIG`. Continuous
  sensors need `SNS_STD_SENSOR_CONFIG` (513) with a sample rate; the request
  is accepted (`result=0`) but no events follow yet, which is a client
  encoding problem, not a sensor one.
