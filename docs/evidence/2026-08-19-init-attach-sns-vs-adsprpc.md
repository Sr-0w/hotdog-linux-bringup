# INIT_ATTACH_SNS against downstream adsprpc

Date: 2026-08-19

## Why

The sensor PD's first fault is a copy between protection domains inside the
DSP, five milliseconds before it ever touches a bus:

```
procinfo_qdi.c:SLPI:Failed to get Service Registry SOC+DOMAIN
procinfo_qdi.c:SLPI:qurt_qdi_copy_from_user failed
```

That is set up by the host at attach time, so the attach was compared against
the vendor driver, `drivers/char/adsprpc.c` from
`OnePlusOSS/android_kernel_oneplus_sm8150`, branch `oneplus/SM8150_Q_10.0`,
which is the tree matching the OxygenOS 10 build on this handset.

## The attach itself is identical

| | mainline `fastrpc_init_attach` | downstream `fastrpc_init_process` |
| --- | --- | --- |
| handle | `FASTRPC_INIT_HANDLE` = 1 | `FASTRPC_STATIC_HANDLE_KERNEL` = 1 |
| method | `FASTRPC_RMID_INIT_ATTACH` = 0 | `REMOTE_SCALARS_MAKE(0, 1, 0)` |
| arguments | 1 in, 0 out: the client id | 1 in, 0 out: `fl->tgid` |
| pd | `SENSORS_PD` = 2 | `fl->pd = 2` |

Nothing to find. The only extra thing downstream does is set
`fl->spdname = "sensors_pdr_adsprpc"`, which registers a service-location
client for protection-domain restart notifications. That path is gated on
`qcom,fastrpc-adsp-sensors-pdr`, and **this handset does not declare it**: the
stock `qcom,msm_fastrpc` node carries only `qcom,fastrpc-adsp-audio-pdr`. So
downstream does not do sensors PDR here either.

## The secure-domain difference is host-side only

Downstream sets `qcom,secure-domains = <0x0f>`, whose bit 2 is the SLPI, while
mainline's SLPI FastRPC node declares `qcom,non-secure-domain`. That looks like
a mismatch and is not one.

On both sides the flag governs which `/dev` node exists and whether an
untrusted caller may use it: mainline through `is_session_rejected()`,
downstream through a `dev_minor` check that returns `-EACCES`. Session
allocation itself asks for a non-secure bank on both sides — downstream calls
`fastrpc_session_alloc_locked(chan, 0, &fl->sctx)` with `secure = 0`, and none
of the three `sdsprpc-smd` context banks is declared secure.

## Where the two really diverge, and it is our side

Downstream allocates the invoke buffer with `fastrpc_buf_alloc()` for every
protection domain, sensors included. Our tree does not:

```c
/*
 * The sensors domain reaches the message buffer directly rather than
 * through its context bank, so it needs one from the reserved pool.
 * A context-bank mapping leaves it addressing memory that is not
 * there, which stalls the interconnect rather than faulting.
 */
if (ctx->fl->sctx->sid && ctx->fl->pd != SENSORS_PD)
        err = fastrpc_buf_alloc(ctx->fl, dev, pkt_size, &ctx->buf);
else
        err = fastrpc_remote_heap_alloc(ctx->fl, dev, pkt_size, &ctx->buf);
```

The `&& ctx->fl->pd != SENSORS_PD` clause is local, carried in the baseline
snapshot rather than coming from upstream. It matters because the two
allocators do not produce the same kind of address:

- `fastrpc_buf_alloc()` allocates through the **session's context-bank device**,
  so the result is an IOVA for that bank, and then tags it:
  `buf->phys += ((u64)fl->sctx->sid << 32)`.
- `fastrpc_remote_heap_alloc()` allocates through the rpdev, out of the
  reserved `fastrpc-shared-pool`, and applies **no SID tag**.

So the sensor PD is handed an untagged physical address where downstream hands
a SID-tagged bank IOVA. The upper bits are how the far side knows which domain
the address belongs to, which is precisely what a copy from another PD has to
resolve. An untagged address is a coherent mechanism for
`qurt_qdi_copy_from_user failed`.

## What that means

The workaround may be causing the failure it was written alongside. It was
added because the context-bank path stalled the interconnect, and that stall is
the thing actually worth understanding: the compute-cb devices do get SMMU
contexts at boot,

```
platform 2400000.remoteproc:glink-edge:fastrpc:compute-cb@1: Adding to iommu group 14
```

so a tagged IOVA through `compute-cb@1`, SID `0x5a1`, ought to translate. Why it
does not is the next question, and it is a better one than any of the attach
differences, because there are none.

Not changed here. Removing the clause reintroduces a hang rather than a fault,
which is a worse failure to debug and needs the stall understood first.
