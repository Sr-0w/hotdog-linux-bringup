# Sensor-PD clock state and the island-mode control

Date: 2026-08-20

This note supersedes the address-space and clock conclusions reached while
reading the root protection-domain copy of the SLPI image.  It also records a
reversible hardware test of the stock sensor framework's island-mode switch.

## The live copy is in the sensor PD

The exact `scc_qupv3_se3_clk_src` string-table witness occurs at file offset
`0x766a48` in the root image and at file offset `0x13c6783` in the coredump.
The latter maps to physical `0x986db794` and virtual `0xb002b794`, establishing
a relocation of `0x17950000` for this sensor-PD segment.

The two static I2C platform configurations start at root offsets `0x766ab4`
and `0x766b04`; their live sensor-PD copies start at `0x13c67ef` and
`0x13c683f`.  There are only two configurations in this firmware.

The second configuration serves I2C instance 3.  It uses serial engine 2, not
serial engine 3:

```
se_clock         b002b778
se_src_clock     b002b790
resource_votes   00000000
clock_config     b002b7a0
clock name       scc_qupv3_se2_clk_src
```

The SE2 clock-domain object is at `0xb03336f0`.  Its plan pointer is
`0xb06338b0`, with eight entries found at coredump offset `0x533b64`:
19.2, 32, 48, 64, 96, 100 and 120 MHz, plus a repeated 19.2 MHz row.

## The sensor-PD clock cache was populated

The sensor-PD globals at virtual `0xb001a000`, coredump offset `0x13b4fef`,
are populated. They contain eight copied plan entries and a non-null pointer
near `0xb001a098` (`0xb06b4400`). This proves that the sensor-PD copy of the
clock data was initialised. It does not prove that the later root-PD QDI
resource request succeeded.

The I2C table requests a 19.2 MHz serial-engine clock for a 400 kHz bus, and
that exact frequency exists in the copied plan.  Both auxiliary Clock DAL
handles at `0xb05c90a8` and `0xb05c90ac` are also non-null
(`0xb05c8fe4`).  The decoded domain has an active first plan row and zero
reference counts. The available Qualcomm Clock DAL implementation gives no
ordinary failure path for this cached state through
`Clock_SetClockFrequency()` or `Clock_EnableClock()`, but the platform call
used by the failing open runs in the root PD, not directly against these
sensor-PD globals.

This rules out the earlier theory that the AP-side SCC clock driver or a
missing frequency plan is the immediate blocker.  The downstream
`msm-ssc-sensors` node configures no serial-engine clocks, and the stock SSC
QUP nodes are disabled, so enabling an AP-side `qcom-geni-se` hierarchy would
not reproduce the stock path.

## Disabling island mode does not restore the sensors

The stock configuration exposes the same switch in two files:

```
/usr/share/qcom/sensors/config/msmnile_power_0.json
/usr/share/qcom/sensors/registry/power.island
```

Both carried `enable_island = 1`.  They were backed up, changed to zero, and
the phone was fully rebooted because stopping the SLPI ends the active SSH
operation and a standalone remoteproc restart times out with `-110` on this
platform.

After booting with island mode disabled, the SLPI and SSC service were present,
but accelerometer, gyroscope, magnetometer, proximity, ambient-light, RGB and
sensor-temperature queries still returned no SUID.  The SX9324 SAR sensor
continued to publish SUID `7335663959f5698867456bc70a6c70ca`.

The original files were then restored byte for byte.  Their verified SHA-256
digests are:

```
msmnile_power_0.json  0baa123b3522fa794eb38a67f5b29faa696c8165f2dd8ef7f6573502694629f4
power.island          e2d005116fba017b5588593fb175770ed6191f41b3f84c5a1cd9740b383336af
```

After the restoration boot, both files again report `enable_island = 1`, the
SLPI is running, `accel` still has no SUID and the physical SAR SUID is present.
The test therefore falsifies the simple hypothesis that the island-status
guard alone blocks these drivers.  It does not prove that every island-related
resource transition is correct.

## Remaining boundary

The low-level setup still returns non-zero before the failing drivers open a
bus port, while the working SAR follows a different com-port path. Static
analysis identifies the shared routine as an `i2c_setup_lpi_resource()`
wrapper with four reference-counted slots. It calls the sensor-PD QDI stub at
`0xb206769c`, which invokes root-PD method `0x10b`,
`I2C_QDI_SETUP_LPI_RESOURCE`. The useful next comparison is therefore inside
that root-PD operation, not the sensor-PD cache. The live `resource_votes`
field being zero is evidence about the current state, but not proof that the
root-PD clock call failed.

The branch that rejects the setup has no local ULog call.  Qualcomm diagnostic
transport may still contain a message, so it should not be described as
semantically silent without a decoded diag capture.
