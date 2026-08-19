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
