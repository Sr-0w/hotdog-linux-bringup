# Remaining hardware: feasibility survey - 2026-08-07

## Why this document exists

The remaining hardware was about to be worked in the order it happened to be
listed, starting with cameras. A feasibility pass first was cheap and changed
the order completely: cameras are by far the largest item and depend on a
subsystem port that does not exist yet, while the fuel gauge below turned out
to be a device-tree description away from working.

Every row here was checked against real sources rather than from memory, and
the first pass got cameras wrong by checking only the 6.16 tree this port
builds from. Current mainline and the OnePlus downstream kernel are both
checked out locally and change the answer, which is why the camera section
carries its own correction.

## Cameras: large, but not blocked

An earlier version of this document called cameras blocked at the foundation.
That was measured against the 6.16 tree this port builds from, and it was wrong
in two ways once current sources are consulted.

**A close relative is now supported.** There is still no `qcom,sm8150-camss`,
but linux-next carries `qcom,sm6150-camss`. SM6150 is the same Titan
generation as SM8150, which makes it a far better template than sdm845, the
nearest supported part at 6.16.

**One of the four sensors is already upstream.** linux-next has
`drivers/media/i2c/s5k3m5.c`. The stock vendor modules identify the four
sensors unambiguously:

| Role | Sensor | Upstream driver |
| --- | --- | --- |
| Main 48 MP | Sony IMX586 | absent |
| Ultra-wide | Sony IMX481 | absent |
| Telephoto | Samsung S5K3M5 | present in linux-next |
| Front, pop-up | Sony IMX471 | absent |

**The register sequences exist and are GPL.** The OnePlus downstream kernel is
checked out locally and carries the full camera stack under
`drivers/media/platform/msm/camera/cam_sensor_module`. That is where sensor
initialisation, clock trees and power sequences live.

What cannot be reused is the OxygenOS userspace: `camera.qcom.so` and the
per-sensor `com.qti.sensor.*.so` modules are proprietary binaries, and the
downstream `cam_req_mgr` architecture has nothing in common with mainline
CAMSS. The work is to extract knowledge, not to port code, which is what this
project's reuse policy already says about published OnePlus kernel source.

So cameras remain the largest item by a wide margin, and still need a CAMSS
port plus three sensor drivers plus libcamera integration, but they are
tractable rather than gated on something that does not exist.

## The rest, ordered by what the tree actually supports

| Subsystem | Mainline support | Assessment |
| --- | --- | --- |
| Fuel gauge | `bq27xxx_battery_i2c` | device-tree only, done below |
| Telephony | `qcom_q6v5_mss` running, `rpmsg_wwan_ctrl`, `qcom_bam_dmux`, ModemManager already installed | the stack exists; needs wiring |
| NFC | `nxp-nci` | plausible; the secure element is separate |
| Motion sensors | `fastrpc` present, and pmaports already runs `hexagonrpcd` on a sibling device | known path, real work |
| Laser rangefinder STMVL53L1 | only `vl53l0x-i2c` | different part, driver to write |
| Hall sensors MXM1120 | none | driver to write |
| Haptics AW8697 | none | driver to write |
| Fingerprint, Warp charge | none | vendor-locked |

## Fuel gauge: working

The stock device tree places the gauge at address `0x55` on the eighth QUP
serial engine, alongside the fast-charge microcontroller. That engine is `i2c8`
and was not enabled. The overlay's own `__fixups__` section resolves
`fragment@69`, which contains `bq27541-battery@55`, to `qupv3_se8_i2c`, which
identified the bus without needing the base device tree.

`i2c8` is described without GPI DMA and at 100 kHz, matching what `i2c4`
already needs on this board.

### The stock name is not the register map

Described as `ti,bq27541`, the gauge answered but reported a state of charge
within a few counts of the voltage, a temperature of -221 C, a full charge
capacity of 0xFFFE, and a cycle count exactly equal to the remaining capacity.

An intermediate theory that these were stale I2C transfers was wrong:
disabling DMA and dropping to 100 kHz changed the numbers but kept cycle count
exactly equal to remaining capacity, which is systematic rather than flaky.

Unbinding the driver and reading the registers directly settled it:

| Register | Raw | Meaning |
| --- | --- | --- |
| `0x02` | 3070 | temperature, 33.9 C |
| `0x04` | 4389 | voltage, 4.389 V on a full cell |
| `0x0c` | 3856 | remaining capacity |
| `0x0e` | 3856 | full charge capacity, equal when full |
| `0x10` | 0 | current, zero on a full battery |
| `0x1c` | 100 | state of charge, percent |
| `0x3c` | 4040 | design capacity |

That is the `bq27421` layout, not the `bq27541` one, where state of charge
would sit at `0x2c` and temperature at `0x06`. It also explains the bogus cycle
count: the `bq27421` family declares that register unavailable, while the
`bq27541` map pointed it at `0x2a`, which holds something else here.

### Result

Described as `ti,bq27411`, which shares that register map, revision `r50`
reports correctly:

```
capacity            100          temp                 351   (35.1 C)
capacity_level      Full         charge_now           3859000
voltage_now         4360000      charge_full          3856000
current_now         -74000       charge_full_design   4040000
```

`charge_full` against `charge_full_design` also gives a real state-of-health
figure for the cell, 3856 of 4040 mAh.

`monitored-battery` is deliberately omitted. The driver can push devicetree
values into a gauge's data memory, with `dt_monitored_battery_updates_nvm`
defaulting to true, and a description should not reprogram a working,
factory-calibrated part.

## Recommended order

1. motion sensors, which unlock rotation and proximity
2. telephony
3. NFC
4. haptics, hall sensors, laser: each a driver to write
5. cameras last: port CAMSS from the sm6150 backend in linux-next, take
   S5K3M5 from upstream, and write IMX586, IMX481 and IMX471 using the
   downstream GPL sources for their register sequences
