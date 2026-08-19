# Why the context-bank path stalls the interconnect

Date: 2026-08-19

## The claim being tested

`fastrpc.c` carries a local clause routing the sensor PD's invoke buffer away
from its context bank:

```c
/*
 * The sensors domain reaches the message buffer directly rather than
 * through its context bank ... stalls the interconnect rather than faulting.
 */
if (ctx->fl->sctx->sid && ctx->fl->pd != SENSORS_PD)
```

That was an assertion with no recorded reproduction. It is now reproduced, and
it is correct.

## Reproduction

The clause was removed and, separately, the SID tag was suppressed for the SLPI
domain to match what the vendor driver does. Built as a module against the
running kernel, `vermagic=6.16.0-sm8150`, so no boot image and no signing were
involved. The auto-attach hook was disabled first so the attach would happen
under observation rather than during boot.

The system booted cleanly and survived until the sensor PD was attached by
hand. From `console-ramoops` after the reset:

```
[ 96.821681] qcom,fastrpc-cb ...:fastrpc:compute-cb@1: invoke handle 1 pd 2 sid 1 addr 0xfffff000
[ 96.871372] [drm:dpu_encoder_frame_done_timeout] enc33 frame done timeout
[ 97.220372] [drm:dpu_encoder_frame_done_timeout] enc33 frame done timeout
[ 99.409391] geni_i2c a80000.i2c: Timeout abort_m_cmd
[ 99.409423] bq27xxx-battery 4-0055: error reading current
```

The invoke goes out carrying `0xfffff000`, and within fifty milliseconds the
display encoder and then the I2C controller — masters with nothing to do with
FastRPC — begin timing out, until the watchdog resets the phone. The file
service had already served its full 3944 operations, so the DSP got that far
and died on the buffer.

## It is not an SMMU stall

The obvious reading is a context bank configured to stall on fault. The vendor
driver does guard against exactly that, on every FastRPC bank:

```c
iommu_domain_set_attr(sess->smmu.mapping->domain,
                DOMAIN_ATTR_CB_STALL_DISABLE, &cache_flush);
```

Mainline has no equivalent, but it does not need one. `arm_smmu_write_context_bank()`
composes `SCTLR` as `CFIE | CFRE | AFE | TRE | M`, with **no `CFCFG`**, so faults
terminate and are reported rather than stalling the master. `CFCFG` is only ever
set by `qcom_adreno_smmu_write_sctlr()`, for the GPU, and `qcom_smmu_500_impl`
does not install a `write_sctlr` hook at all.

And no context fault was reported. A terminated fault would have printed one.

## What it is

Nothing translated the address, and nothing faulted, because the transaction
never reached the SMMU as a translation request. `0xfffff000` is an IOVA that
`dma_alloc_coherent()` handed back for `compute-cb@1`. The sensor PD used it as
a **physical** address, and no slave on the NoC decodes it, so the transaction
never completed and the fabric backed up behind it. Display and I2C timing out
is congestion, not corruption.

So the original comment is exactly right: this domain reaches the message buffer
directly. The reserved pool works because `fastrpc_remote_heap_alloc()` returns a
real physical address out of `fastrpc-shared-pool`, which the DSP can dereference.

## The question this sharpens

The vendor driver hands the sensors PD a context-bank IOVA too. It allocates
through the bank exactly as for every other domain, and only skips the tagging:

```c
if (fl->sctx->smmu.cb && fl->cid != SDSP_DOMAIN_ID)
        buf->phys += ((uint64_t)fl->sctx->smmu.cb << 32);
```

with its IOVA window created explicitly at `arm_iommu_create_mapping(&platform_bus_type,
0x80000000, 0x78000000)`. An untagged IOVA from that window is what the sensors
PD receives downstream, and it works — which means **on downstream the sensor
PD's accesses are translated by the apps SMMU, and on mainline they are not**.

That is the real question, and it is much better posed than before: not "why
does it stall", which is now answered, but why the same master's transactions
are translated under one driver and not the other. The stream IDs are identical
on both sides, `0x5a1` through `0x5a3`, and the `compute-cb` devices do get
contexts at boot (`Adding to iommu group 14`).

## State

Everything was reverted: the module on the device is the original, byte-identical
to the backup, and `fastrpc.c` in the tree is unchanged. The workaround stays,
now with a reproduction behind it rather than an assertion.
