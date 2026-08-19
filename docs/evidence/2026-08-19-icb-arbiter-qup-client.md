# The sensor bus dies at SLPI boot, in the ICB arbiter

Date: 2026-08-19

## A correction first

Every DSP log message quoted in this repository before this note was resolved
against the wrong firmware. `slpi-ulog-coredump.py` only reports format-string
pointers; resolving them needs the image that is actually running. The resolver
was pointed at `cache/oos10.0.13-hd1913-ops/slpi-pil/image/`, an OTA copy, while
the handset runs an image rebuilt from its own `modem_b` partition. The two are
different builds of the same firmware: segment virtual addresses mostly agree,
sizes do not, so pointers landed in plausible-looking but wrong strings.

The tell was there and was misread: resolved strings kept starting mid-word,
which is why the resolver had to walk back to the preceding NUL. That was an
offset error, not a quirk of the logging.

What the same addresses actually say:

| address | resolved before | actual |
| --- | --- | --- |
| `0xb002cfca` | `spi_gpi_callback : GPI driver sending SPI_ERROR_DMA_QUP_NOTIF` | `spi_plat_init: npa_create_sync_client_ex failed` |
| `0xb002cbf4` | `spi_power_on : invalid param` | `bus_iface_callback : ERROR DMA EVT OTHER during data phase` |
| `0xb002c995` | `bus_iface_callback : CLEANUP ERROR: failed to stop RX chan` | `chan %d: type %d: code %d: length %d: tre_idx %d: …` |
| `0xb026d2ac` | `%s: ADSP-DDR BW: Ab=%llu, Ib=%llu; AHB BW …` | `Issue Pair Request (MID: %d, SID: %d) (request: Ib: 0x%08x Ab: 0x%08x)` |

So the `GSI_BUS_ERROR`, `GSI_MCS_STACK_OVRFLOW`, `firmware_load - ERR - IRAM
program fail` and `gpii_init` failures recorded earlier **do not exist**. They
were artefacts. The resolver now points at a copy of `modem_b/image/`, whose
`slpi.mdt` matches the installed `slpi.mbn` segment for segment, all 22 of them.

## What the dump actually contains

Across every non-empty ULog buffer in a coredump taken at the failure, 4216
records, the complete set of errors is four lines:

```
2x NPA Log  FAILED npa_new_client "%s": resource "%s" failed client create (error: %d)
2x NPA Log  FAILED npa_create_sync_client (resource_name: "%s") (client_name: "%s") (client_type: %s)
1x SPI      spi_plat_init: npa_create_sync_client_ex failed
1x TMS      ERR RDY SMP2P bit set successfully
```

With arguments resolved:

```
ts=190927714  npa_create_sync_client (resource: "/icb/arbiter", client: <i2c>, NPA_CLIENT_VECTOR)
ts=190927964  FAILED npa_new_client: resource "/icb/arbiter" failed client create (error: 4)
ts=190929926  npa_create_sync_client (resource: "/icb/arbiter", client: "SPI_QUP_DDR", NPA_CLIENT_VECTOR)
ts=190930086  FAILED npa_new_client "SPI_QUP_DDR": resource "/icb/arbiter" (error: 4)
ts=190930121  spi_plat_init: npa_create_sync_client_ex failed
```

The QUP drivers ask the DSP's bus arbiter for a vector client so they can vote
DDR bandwidth, and the arbiter refuses to create it.

## The arbiter itself is healthy

`/icb/arbiter` is defined and created normally, and other vector clients on it
succeed: `tmsDDRVote` as `NPA_CLIENT_VECTOR`, `Core Init Default Client` as
`NPA_CLIENT_SUPPRESSIBLE_VECTOR`, and three more later. It goes on to service
pair requests throughout the boot:

| MID | SID |
| ---: | ---: |
| 131 | 143 |
| 112 | 25, then 104 |
| 52 | 47 |
| 76 | 243 |
| 180 | 0 |

So this is not a broken arbiter and not a missing NPA framework. Only the QUP
clients are refused, and they are refused at *client creation*, before issuing
any request, which means the master/slave pair in their initial vector has no
route. That is the same fault as the `ICBARB_ERROR_NO_ROUTE_TO_SLAVE` recorded
at the very start of this investigation, now caught at its entry point.

## This happens at SLPI boot, not in the sensor PD

The surrounding records are `rcinit_init.c` group 1, the DSP's own start-up, and
they sit between `servreg_locator.c: Attempting APSS Service Locator Server
connection` and the diag ULog handles coming up. `spi_plat_init` runs while the
SLPI boots.

That rules out a large part of what has been investigated for days. The host
file service, the served registry, `hexagonrpcd`, the FastRPC attach and the
sensor PD are all downstream of this and cannot be the cause: the sensor buses
are already dead before any of them exist. It also explains why the DSP tries
once and never retries, and why nothing the host does afterwards changes the
outcome.

## Where to look next

The question is now narrow: what makes the QUP masters routable in the SLPI's
own bus topology. Candidates worth separating, in order of cost:

- the AP-side interconnect path `qhm_sensorss_ahb` to `qhs_ssc_cfg`, which reads
  `0 0` on the running device, so nothing has ever voted the sensor subsystem's
  own AHB;
- the AOP `load_state` handshake, which mainline does declare, `qcom,qmp` is
  present on the node and no QMP error appears, but which has never been
  observed to succeed;
- anything the arbiter reads at init to build its route table.

## Hypotheses tested against the arbiter failure

Each of these was run on hardware and each leaves
`spi_plat_init: npa_create_sync_client_ex failed` exactly where it was.

**`pd_ignore_unused`.** The clean boot log shows
`PM: genpd: Disabling unused power domains` at 1.12 s, five seconds before the
SLPI boots at 6.37 s, and the cmdline carries `clk_ignore_unused` but had no
power-domain equivalent. If mainline collapsed the SSC island before the DSP
enumerated its bus, the QUP masters would be missing from the arbiter's
topology, which would match the two root causes already found in this project.
A boot image with `pd_ignore_unused` added, packed and AVB-signed, boots and the
parameter is live in `/proc/cmdline`. The SPI buffer still holds one record and
it is the same failure. Reverted, because keeping unused domains powered would
also disturb the suspend work that is currently at 100 %.

**The AOP handshake.** `qcom,qmp` is present on the SLPI node,
`c300000.power-management` is bound to `qcom_aoss_qmp`, and no QMP error is
logged, so the `load_state` signal mainline declares is being delivered.

**The interconnect vote.** Dropped without testing. `qhm_sensorss_ahb` reads
`0 0`, but an application-processor bandwidth vote cannot add a route to a table
the DSP builds for itself, and the arbiter refuses the client before any request
is issued.

## A further correction

`ICBARB_ERROR_NO_ROUTE_TO_SLAVE`, the string this whole investigation was named
after, **does not appear anywhere in the firmware the handset runs**. Searching
every segment of the image rebuilt from `modem_b` finds only `icbarb`,
`icbarb_post`, `%s: Failed creation of MIPS icbarb client` and
`%s: icbarb client create failed:M=%u, S=%u`. Like the ADSP-DDR bandwidth lines,
it came from a different image.

The message that would name the rejected master and slave is that last one, and
it is not written to any ULog buffer: all 51 buffers were enumerated, the 37
carrying data were dumped, and it appears in none of them. It presumably goes to
the DSP's diag channel, which mainline has no transport for. Recovering the
master and slave identifiers therefore needs either a diag path or static
analysis of Hexagon code, since the client name is materialised as an immediate
rather than through a data pointer.

## The bus-level symptom, read correctly

The `I2C_error` buffer, resolved against the right image, is not a DMA failure.
It is three sensors refusing to answer:

```
ERROR nack
bus_iface_callback : ERROR DMA EVT OTHER during data phase   (x2)
Performing cancel sequence, for ctxt 0xb0028f20   (and 0xb0028f98)
```

repeated for two contexts. The `I2C` buffer alongside it holds ordinary
transfer bookkeeping, channels, TREs, buffer descriptors, so the controller and
its DMA are working. The DSP drives the bus, addresses the part, and gets no
acknowledgement.

## The sensor rails are up

A systematic NACK on several parts points at power, and the DSP does ask for it
correctly. From the NPA log:

```
/pmic/client/sensor_vddio -> /pm/ldoc8/en  = 1
/pmic/client/sensor_vdd   -> /pm/ldoc7/mode = 7
                             /pm/ldoc7/mV   = 0xbc0   (3008 mV)
                             /pm/ldoc7/en   = 1
   ... the NACKs ...
/pmic/client/sensor_vdd   -> /pm/ldoc7/en  = 0
/pmic/client/sensor_vddio -> /pm/ldoc8/en  = 0
```

`ldoc7` and `ldoc8` are PM8150L LDO 7 and 8, and the application processor sees
both enabled:

| regulator | state | voltage |
| --- | --- | --- |
| `pm8150l` `ldo7` | enabled | 2,856,000 µV |
| `pm8150l` `ldo8` | enabled | 1,800,000 µV |

The DSP asks 3,008 mV where the rail sits at 2,856 mV, but every part on these
buses is specified well below that, so it is noted rather than suspected.

Power is therefore not the blocker, and neither is the controller. What remains
is that both QUP drivers failed to obtain their `/icb/arbiter` bandwidth clients
at init: the I2C one carries on and gets NACKs, the SPI one gives up, which is
why the accelerometer and gyroscope on SPI never appear at all.

## Boot ordering eliminated

Stock loads the SLPI from userspace long after Android is up, while mainline
boots it 6.4 seconds in. A module parameter, `slpi_auto_boot=0`, was added to
`qcom_q6v5_pas` to test whether that matters. With it, the SLPI stays offline
through boot and starts cleanly on demand at 90 seconds of uptime, with the
modem and ADSP already running and `pd-mapper` serving.

The result is identical: `SPI` holds one record, `spi_plat_init:
npa_create_sync_client_ex failed`, and no sensor publishes a SUID. Reverted.

Worth recording separately: the SLPI stops cleanly now, in about a second, but
a *restart* still fails. `start` reaches `Booting fw image` and then times out,
`can't start rproc slpi: -110`, so the DSP never signals ready on a second
start. A first start, whenever it happens, works.

## The abort happens before the QUP is ever touched

The firmware contains a full set of QUP bring-up messages —
`firmware_load - qup-%d Done !`, `firmware_load - ERR - IRAM program fail`,
`gpii_init - WARN - qup-%d gpii-%d initialized!`,
`gpii_init - ERR - qup-%d gpii-%d not ready`, seventeen strings in total. **None
of them appears anywhere in the capture**, success or failure.

So the SSC QUP's microcode is never loaded and its GPI is never initialised.
`spi_plat_init` asks `/icb/arbiter` for its bandwidth client, is refused, and
returns before reaching any of that. The chain is complete and consistent:
no bandwidth client, no QUP bring-up, no SPI, and on the I2C side a controller
that goes as far as issuing transfers and collects NACKs.

Also worth noting from the same strings: the SLPI's own QUP driver names GCC
clocks, `gcc_qupv3_wrap0_core_clk`, `gcc_qupv3_wrap_0_m_ahb_clk` and the rest,
and the SSC pin groups appear as `ssc_qup0` through `ssc_qup3` under audio
function names, `aud_spi_pri_*[ssc_qup2_*]` being the accelerometer's SPI.

## Further hypotheses tested and closed

- **The sensors are not reachable from the application processor.** Neither the
  downstream SoC device tree nor any of the ten stock overlays declares a sensor
  anywhere, so there is no I2C bus on the application-processor side to bind a
  mainline IIO driver to. The parts exist only behind the SSC.
- **NPA client-id exhaustion.** The firmware has
  `can't find available clientID max=%u, numofclients=%u`; its pointer appears
  zero times in the coredump, so the pool was never exhausted.
- **The arbiter's own rejection path was not taken.**
  `%s: icbarb client create failed:M=%u, S=%u` also appears zero times, in the
  ULog buffers and in the raw 20 MB dump alike. The refusal comes from the
  generic `npa_new_client`, not from the arbiter's validation, which is why the
  master and slave identifiers are nowhere to be found.
- **A different firmware build.** The OTA copy of `slpi.mbn` was repacked and
  installed; TrustZone rejects it outright, `error -22 initializing firmware`.
  Only the image from this handset's own `modem_b` partition authenticates.

## Where this stands

The fault is localised, correctly read, and reproducible: the sensor DSP cannot
obtain the bus-bandwidth client its QUP drivers need, and everything else
follows. Every lever the application processor has over that has been tested
and none of them moves it.

What would move it next is not another hypothesis but a tool: either a diag
transport to read the DSP's F3 messages, where the rejected master and slave are
printed, or static analysis of the Hexagon code around `/icb/arbiter`'s
client-create callback. The client name is materialised as an immediate rather
than through a data pointer, so the latter needs a real disassembler.
