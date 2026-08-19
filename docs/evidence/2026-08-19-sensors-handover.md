# Sensors: where the investigation actually stands

Date: 2026-08-19

This supersedes the framing of every earlier sensor note. Read it before
picking the work up.

## The one fault

At SLPI boot, during the DSP's own `rcinit`, both QUP drivers ask the DSP's bus
arbiter for a bandwidth client and are refused:

```
npa_create_sync_client (resource: "/icb/arbiter", client: "SPI_QUP_DDR", …)
FAILED npa_new_client "SPI_QUP_DDR": resource "/icb/arbiter" (error: 4)
spi_plat_init: npa_create_sync_client_ex failed
```

Nothing downstream of that works. None of the seventeen QUP bring-up messages
in the firmware is ever emitted, so the SSC QUP microcode is never loaded and
the GPI never initialised. The I2C log entries that follow are the driver
queueing descriptors into an engine that was never started, and the `ERROR nack`
records are the result, not an independent problem. The accelerometer and
gyroscope are on SPI, which aborts outright.

Because this happens during the DSP's own boot, everything the host does
afterwards is irrelevant to it: the file service, the served registry,
`hexagonrpcd`, the FastRPC attach and the sensor PD all come later.

## Disassembled, not guessed

`scripts/slpi/build-slpi-elf.py` turns the split PIL image into an
`elf32-hexagon` file; `llvm-objdump -d` handles it. The two failing call sites
differ from every working one by a single argument:

| site | client | third argument |
| --- | --- | ---: |
| `b01bf770` | `tmsDDRVote` | `0x8` — succeeds |
| `b0152a70`, `b01f6554` | from a table | `0x8` — succeed |
| `b0034d18` | `SPI_QUP_DDR` | `0x10` — refused |
| `b00312dc` | the I2C client | `0x10` — refused |

The `4` is the return value of `/icb/arbiter`'s own create-client callback,
reached at `b01e2db8` through `memw(memw(resource+0x14)+0x10)`.

## Everything ruled out, with the evidence

| hypothesis | verdict |
| --- | --- |
| host file service, registry, socinfo, project files | complete, 3944 operations, zero failures; and it runs after the fault |
| `hexagonrpcd`, FastRPC attach, sensor PD | all later than the fault |
| `INIT_ATTACH_SNS` vs downstream `adsprpc` | byte-for-byte equivalent; the PDR path downstream would take is gated on a property this handset does not declare |
| secure vs non-secure FastRPC domain | host-side access control on both sides; both allocate non-secure sessions |
| `qcom,nsessions` on the SLPI context bank | booted on hardware, inert; the sensor PD uses `compute-cb@1` |
| `pd_ignore_unused` | booted on hardware, identical failure |
| SLPI boot ordering | started at 90 s with modem, ADSP and pd-mapper up: identical failure |
| SMMU / IOMMU | unknown streams are bypassed, `disable_bypass=0`, no faults |
| interconnect votes | cannot add routes to a table the DSP builds itself |
| AOP `load_state` | `qcom,qmp` present, `c300000.power-management` bound, no error |
| sensor rails | PM8150L ldo7 and ldo8 enabled, 2.856 V and 1.8 V; every part is specified from 1.7 V |
| reserved memory | downstream `removed_regions` is covered exactly by our `tz_mem`, `stock_removed_gap` and `hotdog_removed_gap` |
| a different firmware build | the OTA image is rejected by TrustZone, `error -22` |
| driving the parts from the application processor | no sensor appears in any AP-side device tree, SoC or overlay; they exist only behind the SSC |

## What is left

The arbiter's create-client callback, and only that. It is installed at runtime
into structures in writable data at `0xb032a074` and `0xb032a0c8`, so it cannot
be found by searching for pointers: the static image holds only the name
strings. Finding it needs a call graph or a proper interactive disassembler,
which grep over `llvm-objdump` output is not.

The alternative is a diag transport for the DSP's F3 messages. The firmware
contains `%s: icbarb client create failed:M=%u, S=%u`, which names the rejected
master and slave, but it is written to diag rather than to any ULog buffer: all
51 buffers were enumerated, the 37 with data were dumped, and its pointer
appears nowhere in the 20 MB coredump either.

## Two corrections that must not be lost

Every DSP log line quoted in this repository before today was resolved against
an OTA copy of the firmware rather than the image the handset runs. They are
different builds. `GSI_BUS_ERROR`, `GSI_MCS_STACK_OVRFLOW`,
`spi_power_on : invalid param` and the GPI firmware-load failures **do not
exist**. Neither does `ICBARB_ERROR_NO_ROUTE_TO_SLAVE`, the string this whole
investigation was named after: it is absent from the firmware.

Always resolve against `/mnt/modem_b/image`, and remember that `llvm-objdump`
prints these addresses in signed form.
