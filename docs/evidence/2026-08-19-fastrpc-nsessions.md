# qcom,nsessions on the SLPI FastRPC bank: tested, inert

Date: 2026-08-19

## The hypothesis

The sensor PD's first fault is internal to the DSP and looks like a memory
problem between protection domains, not a bus problem:

```
procinfo_qdi.c:SLPI:Failed to get Service Registry SOC+DOMAIN
procinfo_qdi.c:SLPI:qurt_qdi_copy_from_user failed
        ... 5 ms later ...
spi_gpi_callback : GPI driver sending SPI_ERROR_DMA_QUP_NOTIF
```

Downstream declares three FastRPC context banks for `sdsprpc-smd`, SIDs
`0x5a1`, `0x5a2` and `0x5a3`, and marks the last one `shared-cb = <0x04>`.
Mainline declares the same three SIDs and marks nothing; a comment left in
`sm8150.dtsi` had already flagged the difference. The mainline equivalent is
`qcom,nsessions`, which `fastrpc_cb_probe()` uses to duplicate a session, and
which sc7180, sa8775p and sm6350 all set on the last bank of a domain.

## Result

`qcom,nsessions = <4>` on `compute-cb@3` boots and changes nothing. The
property is live in the running tree, the sensor core registers `service 400`
on QRTR node 9, and every data type still answers `no SUID`.

The reason is visible in the kernel log: the sensor PD takes its session on
**`compute-cb@1`**, not on the bank that was given extra sessions.

```
qcom,fastrpc-cb 2400000.remoteproc:glink-edge:fastrpc:compute-cb@1:
        invoke handle 3 pd 2 sid 1 addr 0xfee00000
```

`fastrpc_session_alloc()` takes the first free session, and with three banks
free there is never any reason to reach the duplicated ones. Adding sessions to
a bank nothing contends for cannot change behaviour. Whether downstream's
`shared-cb` means the same thing as `qcom,nsessions`, or whether it also pins
the sensors PD to that bank, is not established.

The property is therefore not carried in the tree. The comment stays, now
pointing here.

## What the attempt actually established

The three boot failures along the way had nothing to do with the device tree.

1. **The first failure was an unsigned image.** Documented separately in
   [2026-08-19-boot-image-avb-footer.md](2026-08-19-boot-image-avb-footer.md).
2. **The second and third were the slot itself.** Even a correctly signed image
   whose payload is byte-identical to the running one fails to boot from slot A,
   because `vbmeta_a` and `dtbo_a` still hold what the handset shipped with:

   | partition | sha256 (16) |
   | --- | --- |
   | `vbmeta_a` | `9c3bd240a04103c4` |
   | `vbmeta_b` | `46e15d8f02110b55` |
   | `dtbo_a` | `66dba793d7efc701` |
   | `dtbo_b` | `d23564d42c989c2b` |

   postmarketOS was only ever installed to slot B. Cloning `vbmeta_b` and
   `dtbo_b` onto slot A makes it bootable, and the signed control image then
   boots from it in one attempt.

**Slot A is now a usable test vehicle**, cloned from B, which is what makes a
boot experiment cheap: write the candidate to `boot_a`, `qbootctl -s a`, and
slot B stays untouched as the fallback. The original `vbmeta_a` is preserved at
`/root/vbmeta_a.orig` on the device.

One operational note: `qbootctl -c` reports the slot that is *running*, not the
one set active for the next boot, so it must not be used to check whether
`qbootctl -s` worked.
