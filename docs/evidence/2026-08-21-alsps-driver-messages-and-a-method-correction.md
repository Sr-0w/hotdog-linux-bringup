# The ALS driver's messages in plain text, and a correction that matters

Date: 2026-08-21

The compact `(file, line)` descriptors resolve for `sns_alsps_sensor.c`, file
id `0x7d`, the same way they did for `sns_com_port_i2c.c`. That gives the
driver's whole message set, and it changes what the earlier analysis was
actually looking at.

## The messages

```
sns_alsps_sensor.c:register_cct_devinfo
sns_alsps_sensor.c:Error decoding registry event
line 504  Registry read event for group %s received, %s sensor is_dri:%d, hardware_id:%…
line 606  Registry read event for group %s received %s sensor bus_type:%d bus_instance:%…
line 611  min_bus_speed_KHz :%d max_bus_speed_KHz:%d reg_addr_type:%d
line 617  interrupt_num:%d interrupt_pull_type:%d is_chip_pin:%d
line 684  pa data[0] = %d (ver: %d), data[1] = %d (ver: %d), …
line 737  PS near_thd = %d (ver: %d), far_thd = %d (ver: %d), offset1 = %d …
line 769  ALS data[0] = %d (ver: %d), data[1] = %d (ver: %d)
line 777  CCT data[0] = %d (ver: %d), data[1] = %d (ver: %d)
line 1014 Received unsupported registry event msg id %u
line 1076 Unsupported sensor %d

sns_alsps_sensor_instance.c:130  sensor %d, alsps_inst_init is_dri = %d,
sns_alsps_sensor_instance.c:135  fail to open com port %d
sns_alsps_sensor_instance.c:178  fail to register com port %d
sns_alsps_sensor_instance.c:224  alsps_inst_init: Update fac
```

## The correction

**Opening the com port belongs to `sns_alsps_sensor_instance.c`, not to the
sensor.** In SEE the sensor publishes its SUID at init; an *instance* is
created only when a client subscribes, and that is where `alsps_inst_init`
opens and registers the com port.

So a driver that never publishes a SUID never reaches the com port at all, and
the long analysis of the port-open path — the flag byte at `+0x24`, the pool
allocation, `memub(port+0x4)`, the refusal that logs nothing — was describing
a path that only runs *after* the problem. It explains nothing about the
missing SUIDs. Recorded so nobody re-derives it.

The failure is at sensor level, and `Unsupported sensor %d` at line 1076 is the
message to look for.

## What was found on the way, and ruled out

`als_type` is the field at driver state `+0x27c`, named by the line-536 message
`als_type %d ps_type %d is_unit_device %d is_als_dri…` whose arguments are
exactly the values read around it. The driver publishes `wise_light` when it
equals 2 and `ambient_light` otherwise; both were queried and neither
registers.

The `cct` registry group the driver asks for was missing again, having been
replaced when the LineageOS config set was deployed and the factory registry
restored. Recreated in `msmnile_alsps.json` and in the registry, in an
otherwise clean environment — complete 65-file config set, factory registry
with `devinfo`, vendor rail values. The DSP now requests it, eight times, and
the group survives the boot:

```
cct requested by the DSP : 8
alsps groups present     : 13
```

and nothing changes: `sars` registers, `ambient_light`, `wise_light`,
`proximity`, `rgb`, `accel` and `gyro` do not. Unlike the first attempt at this
test, this one had a clean baseline and a working control, so it settles it.
The group is kept — the driver asks for it and `devinfo.rgb` names it.
