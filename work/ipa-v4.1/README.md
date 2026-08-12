# IPA v4.1 for SM8150: work in progress

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
