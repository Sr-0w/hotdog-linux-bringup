# Remaining hardware: feasibility survey - 2026-08-07

## Why this document exists

The remaining hardware was about to be worked in the order it happened to be
listed, starting with cameras. A feasibility pass first was cheap and changed
the order completely, because cameras turned out to be blocked at a level no
amount of device-tree work reaches.

Each row below was checked against the kernel tree actually used by this port,
not from memory.

## Cameras: blocked at the foundation

Three independent blockers, all of which must be solved before a single frame
can be captured.

**No SM8150 CAMSS backend exists.** The mainline camss driver carries
compatibles for msm8916, msm8953, msm8996, sc7280, sc8280xp, sdm660, sdm670,
sdm845, sm8250, sm8550 and x1e80100. SM8150 sits between sdm845 and sm8250 and
is absent from both the driver and the bindings. Adding it means a new
CSIPHY/CSID/VFE description with this SoC's register offsets, clocks, power
domains and interconnect paths.

**None of the four sensors has a mainline driver.** The stock vendor partition
identifies them unambiguously through its per-sensor modules:

| Role | Sensor | Mainline driver |
| --- | --- | --- |
| Main 48 MP | Sony IMX586 | absent |
| Ultra-wide | Sony IMX481 | absent |
| Telephoto | Samsung S5K3M5 | absent |
| Front, pop-up | Sony IMX471 | absent |

Mainline has imx208, imx214, imx219, imx258, imx274, imx283, imx290, imx296,
imx319, imx334, imx335, imx355, imx412 and imx415, and for Samsung only
s5k5baf and s5k6a3. Sensor drivers need register initialisation sequences that
in practice only exist in vendor code.

**libcamera** then needs a pipeline handler for whatever the first two produce.

Cameras are therefore the worst available starting point: maximum effort, and
gated on a kernel subsystem port that does not exist yet.

## The rest, ordered by what the tree actually supports

| Subsystem | Mainline support | Assessment |
| --- | --- | --- |
| Fuel gauge BQ27541 | `bq27xxx_battery_i2c` with a `ti,bq27541` compatible | device-tree only, done below |
| Telephony | `qcom_q6v5_mss` running, `rpmsg_wwan_ctrl`, `qcom_bam_dmux`, ModemManager already installed | the stack exists; needs wiring |
| NFC | `nxp-nci` | plausible; the secure element is separate |
| Motion sensors | `fastrpc` present, and pmaports already runs `hexagonrpcd` on a sibling device | known path, real work |
| Laser rangefinder STMVL53L1 | only `vl53l0x-i2c` | different part, driver to write |
| Hall sensors MXM1120 | none | driver to write |
| Haptics AW8697 | none | driver to write |
| Fingerprint, Warp charge | none | vendor-locked |

## Fuel gauge: described, reporting partly wrong values

The stock device tree places the gauge at address `0x55` on the eighth QUP
serial engine, alongside the fast-charge microcontroller. That engine is `i2c8`
and was not enabled. The overlay's own `__fixups__` section resolves
`fragment@69`, which contains `bq27541-battery@55`, to `qupv3_se8_i2c`, which
is how the bus was identified without the base device tree.

Revision `r48` (`0054`) enables `i2c8` and describes the gauge. It probes and
registers as `bq27541-0` alongside the existing charger.

`monitored-battery` is deliberately omitted. On chips with writable data memory
the driver pushes devicetree values into the gauge's non-volatile memory, with
`dt_monitored_battery_updates_nvm` defaulting to true. A description should not
reprogram a working, factory-calibrated gauge. This kernel also has
`CONFIG_BATTERY_BQ27XXX_DT_UPDATES_NVM` unset, but the property is still not
worth carrying.

Some values are right and some are clearly not:

| Property | Value | Verdict |
| --- | --- | --- |
| `manufacturer` | Texas Instruments | correct |
| `voltage_now` | 3,897,000 | plausible |
| `charge_full_design` | 4,040,000 | plausible against a 4085 mAh cell |
| `current_now` | -1,770,000 | plausible |
| `capacity` | 3842 | must be 0-100 |
| `temp` | -2211 | would be -221 C |
| `charge_full` | 65,534,000 | 0xFFFE, an error value |
| `cycle_count` | 3784 | identical to `charge_now` |

`cycle_count` reading exactly what `charge_now` reads is the tell: the register
offsets are shifted rather than the values being nonsense. The part answers,
and the fields the mainline `bq27541` map places early are correct while later
ones are not.

Not resolved. The next step is identifying the exact variant: `bq27542`,
`bq27546` and `bq27742` share the `bq27541` register map in this driver, so if
the part is one of the neighbouring families its map differs. A raw register
dump would settle it, but the driver holds the address and forcing a
concurrent access to a battery gauge is not worth it; unbinding the driver
first is the clean way.

## Recommended order

1. finish the fuel gauge variant
2. motion sensors, which unlock rotation and proximity
3. telephony
4. NFC
5. haptics, hall sensors, laser: each a driver to write
6. cameras last, and only after an SM8150 CAMSS port exists
