# IPA v4.1 for SM8150: work in progress

> Historical development note. IPA v4.1 now starts on Hotdog and creates
> `rmnet_ipa0`; current limitations are tracked in
> [the status matrix](../../docs/status.md). The steps below preserve how the
> implementation reached that result.

`ipa_data-v4.1.c` here is complete and written against mainline's structures,
not copied from downstream. Every number in it is extracted from
`src/lineage/android_kernel_oneplus_sm8150`, and the derivation is recorded in
`docs/evidence/2026-08-12-ipa-v41-memory-map.md`.

## What is done

The platform data file: QSB limits, all eight endpoints with their channel,
endpoint, TLV and AOS counts, both resource tables, the twenty-four IPA-local
memory regions in canary-count form, interconnects and power data.

Two things in it were decisions rather than transcriptions, and both are
recorded here so they can be challenged:

- `imem_addr` is set to 0x146a8000. sdm845 uses 0x146bd000 and this needs
  confirming against the SM8150 IMEM layout before the driver is trusted.
- `core_clock_rate` is set to 100 MHz. sdm845 runs 75 MHz and the stock tree
  votes through the legacy MSM bus scaling rather than stating a rate, so this
  is an estimate from the generation rather than a measured figure.

The interconnect bandwidths are currently sdm845's. The stock node carries
five performance cases across four paths in `qcom,msm-bus,vectors-KBps`, so
real figures can be derived from it, but they have to be translated into
mainline's named-path form rather than lifted.

## What remains

### `reg/ipa_reg-v4.1.c`

Mainline has no register set for this generation and `ipa_regs()` would return
NULL, so the driver cannot probe without it. The work is small and fully
specified.

Downstream inherits register definitions forward, and the counts settle what
the delta is: `IPA_HW_v4_1` declares **zero** overrides, so v4.1 is v4.0
exactly, and `IPA_HW_v4_2` declares five. Mainline already ships the v4.2 set,
so v4.1 is that file with five entries changed back:

| Register | v4.1 (= v4.0) | v4.2 |
|---|---|---|
| `IDLE_INDICATION_CFG` | 0x220 | 0x240 |
| `ENDP_INIT_HOL_BLOCK_TIMER_n` | 0x830 stride 0x70, fields 10/22 | 0x830 stride 0x70, fields 8/16 |
| `ENDP_FILTER_ROUTER_HSH_CFG_n` | 0x85c stride 0x70 | absent |
| `HPS_FTCH_ARB_QUEUE_WEIGHT` | 0x5a4 | absent |
| filter/route hashing | `FILT_ROUT_HASH_FLUSH` 0x14c | `FILT_ROUT_HASH_EN` 0x148 |

The two registers v4.2 lacks are already described in mainline's own idiom in
`reg/ipa_reg-v3.5.1.c`, and `ENDP_FILTER_ROUTER_HSH_CFG` sits at 0x85c with
stride 0x70 there, which is exactly the v4.1 placement. Only
`FILT_ROUT_HASH_FLUSH` needs its offset moved, from 0x90 to 0x14c.

`HPS_FTCH_ARB_QUEUE_WEIGHT` has no counterpart in mainline's register
enumeration, so it is dropped rather than added; mainline does not program it.

This also agrees with a predicate mainline already carries: filter and route
hashing is supported on every version below 5.0 except 4.2, which is precisely
the difference above.

### Wiring

- `IPA_DATA_VERSIONS` and `IPA_REG_VERSIONS` in the Makefile gain `4.1`.
- `ipa_data.h` gains `extern const struct ipa_data ipa_data_v4_1;`.
- `ipa_main.c` gains a `qcom,sm8150-ipa` match entry.
- `ipa_regs()` gains a v4.1 case; `gsi_regs()` maps v4.1 to `gsi_regs_v4_0`,
  which already exists and is correct because v4.1 pairs with GSI 2.0.

### Device tree

Downstream describes one `ipa-base` at 0x1e00000 for 0x34000 with `gsi-base`
at 0x1e04000 inside it. Mainline wants three ranges named `ipa-reg`,
`ipa-shared` and `gsi`, so the node is rewritten against the v4.1 register
layout rather than copied. It also needs the modem SMP2P entries, the
interconnects, and the two firmware reservations the board already carries.

## Status: implemented, untested

Revisions `0144` through `0146` are in the kernel aport and `r161` builds
clean. `ipa.ko` is produced, and the compiled device tree carries the node
enabled, with `memory-region` resolved to `ipa_fw_mem`, streams 0x520 and
0x522, the SMP2P entries and both interrupts.

Nothing here has touched hardware. The first run will exercise, in order:
whether the driver probes at all, whether GSI initialises, whether the modem
answers the setup-ready handshake, and whether `rmnet` appears for
ModemManager to use.

Two values in the platform data are judgements rather than extractions, and
they are the most likely first failures:

- `imem_addr` is 0x146a8000. sdm845 uses 0x146bd000 and this needs confirming
  against the SM8150 IMEM layout.
- `core_clock_rate` is 100 MHz. The stock tree votes through the legacy MSM
  bus scaling and never states a rate, so this is an estimate.

The interconnect bandwidths are still sdm845's. The stock node carries five
performance cases across four paths, so real figures can be derived once the
driver runs.

## First hardware runs: r161 and r162

The driver reaches the handset and each run fails further along than the last,
which is what makes the errors useful.

**r161.** `platform 1e40000.ipa: Adding to iommu group 4`, so the node, its
streams and the match entry are all correct, then:

```
ipa 1e40000.ipa: empty memory region 11
ipa 1e40000.ipa: probe with driver ipa failed with error -22
```

That was my error. `ipa_mem_valid_one()` rejects a region whose size and canary
count are both zero, and I had transcribed downstream's zero-sized `apps_hdr`
literally. Mainline marks `IPA_MEM_AP_HEADER` optional and neither the v3.5.1
nor the v4.2 data file declares it at all. Removed in r162.

**r162.** Past that check, into the hardware:

```
ipa 1e40000.ipa: channel 4 limited to 256 TREs
ipa 1e40000.ipa: region 14 ends beyond memory limit (0x00002000)
```

The driver read the IPA SRAM size from the hardware and got 8 KB. The
downstream partition runs to `end_ofst = 0x2800`, which is 10 KB.

The register read is not in doubt: `IPA_SHARED_MEM_SIZE` sits at 0x54 in every
downstream version, declared once at v3.0 and inherited, and mainline's v4.2
file uses 0x54 as well. So the handset is telling us its AP-visible shared
memory is 8 KB.

That leaves a real question rather than a typo, and it should be settled rather
than guessed. Two candidates:

- `ipa_4_1_mem_part` may cover more than the AP window. The last two regions,
  `modem` ending at 0x23fc and `uc_descriptor_ram` at 0x2400, are the ones that
  overflow, and the uC descriptor RAM in particular is plausibly addressed
  outside the shared window rather than inside it. For comparison, sdm845's
  mainline map ends at exactly 0x2000 with its uC event ring as the last
  region.
- the downstream v4.1 row may be shared with a different SoC of the same IPA
  generation whose SRAM is larger.

Reading the `SHARED_MEM_SIZE` register directly on the handset, and comparing
`ofst_start` against the reported base address, will distinguish these. That is
the next measurement, and it needs no guesswork.

The `channel 4 limited to 256 TREs` line is informational: the command channel
asks for 512 TREs and the event ring caps it. sdm845 carries the same pair of
numbers, so this is expected rather than a defect.

## r163 and r164: the driver comes up

**r163.** The 8 KB limit was not the hardware at all. `ipa->mem_size` is set
from `resource_size()` of the `ipa-shared` range in the device tree, and I had
copied sc7180's 0x2000, which fits sc7180's map exactly and not ours. Widening
it to 0x4000 produced the answer that settles the earlier question:

```
ipa 1e40000.ipa: limiting IPA memory size to 0x00002800
ipa 1e40000.ipa: IPA driver initialized
```

The hardware reports 0x2800, exactly the downstream `end_ofst`. The memory map
extracted from downstream is correct, and both candidate explanations recorded
above were wrong: the map covers the AP window precisely, and it is this SoC's
map. Only my device tree window was short.

**r164.** With the map right, probe reached firmware loading and stopped:

```
Direct firmware load for ipa_fws.mdt failed with error -2
```

The AP has no IPA firmware on this system and none is packaged. Rather than
extract it, the loader is handed to the modem, which is already running:
`qcom,gsi-loader = "modem"`. That is the modern form of the legacy
`modem-init` property.

The driver then binds:

```
ipa 1e40000.ipa: IPA driver initialized
ipa 1e40000.ipa: received modem starting event
ipa 1e40000.ipa: received modem running event
```

`/sys/bus/platform/drivers/ipa/1e40000.ipa` exists, so IPA v4.1 is supported on
this SoC for the first time.

## Where it stops

No `rmnet` netdev yet, and ModemManager still finds no modem. The remoteproc
notifications arrived, but the IPA-to-modem QMI exchange that follows them has
produced nothing in the log, and it is that exchange which creates the network
device. That is the next thing to instrument.

The two values flagged as estimates are still unproven. `core_clock_rate` and
the interconnect bandwidths did not prevent the driver coming up, but nothing
has moved traffic yet, so neither is validated. `imem_addr` is likewise
untested.

## r165: the network device appears

`gsi-loader = "modem"` was the wrong choice, and the interrupt counters said
so plainly: `ipa-clock-query` and `ipa-setup-ready` were both registered on
`smp2p-mpss` and both sat at zero. The stock modem never raises them because it
expects the AP to load the IPA firmware, the way OxygenOS does.

The firmware is on the handset, in the stock vendor partition. `vendor_a.img`
was already extracted on the host, and `debugfs` reads it without mounting
anything:

```
/firmware/ipa_fws.mdt  plus  ipa_fws.b00 .. ipa_fws.b04
```

Those are merged into a single `ipa_fws.mbn` by walking the ELF program
headers and writing each segment at its `p_offset`, the same shape as
`pil-squasher`. The result is 41280 bytes and is installed as
`qcom/sm8150/oneplus/hotdog/ipa_fws.mbn`, with `qcom,gsi-loader = "self"` and
a matching `firmware-name`.

That completes the bring-up:

```
ipa 1e40000.ipa: IPA driver initialized
ipa 1e40000.ipa: IPA driver setup completed successfully
ipa 1e40000.ipa: received modem running event
```

and the network device exists:

```
lo  rmnet_ipa0  usb0  wlan0
```

## Packaging note

`ipa_fws.mbn` is installed by hand, exactly as `slpi.mbn` is. The snapshot
validator refuses binaries in the aports tree, so both need adding to the
firmware package through whatever path already produces the other blobs.
