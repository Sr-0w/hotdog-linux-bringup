# R6 UFS live-probe failure

## Purpose

The direct Linux 6.17 path reaches the native SM8150 UFS host and PHY but its
first device-init NOP fails. A temporary module was built against the exact R6
Linux 4.14.357 kernel to compare the known-working downstream controller with
the direct-mainline state. The intended sequence was `ufshcd_hold()`, bounded
register reads and local `DME_GET` operations, then `ufshcd_release()`.

This approach is unsafe on the tested OnePlus 7T Pro and must not be repeated.

## Test identity

| Item | Value |
|---|---|
| Date | 2026-08-01 |
| R6 boot ID | `dde14674-78b3-4485-ab13-f354e5b70eb0` |
| Kernel | `4.14.357-openela-perf #6-postmarketOS` |
| Module SHA256 | `2100b2c93190fdbfbdb61b8ef2d77b5dfc5b6378c13eacc898591fb1ce00396f` |
| Full dmesg size | 480,336 bytes |
| Full dmesg SHA256 | `7fb4e08ed03856bfdddd43c8a49f87692303c01768408112d77767f4e0d2a4dd` |
| Task-state SHA256 | `38a929c9ab91508f8778600a5dcf33d881174d82509d8aa74e9cb75886d27a46` |
| Kernel-stack SHA256 | `e6f193ad9764099ccf418b8928cec436e68a87bbaffe33d4b2f61876aaed4864` |

The module release string and imported-symbol CRCs matched the running kernel.
The failure was therefore runtime behavior, not a module ABI mismatch.

## Known-working boot state

Before loading the module, the normal R6 boot log established a healthy
downstream baseline without extra controller access:

```text
ufshcd_print_pwr_info: gear=[4, 4], lane[2, 2],
                       pwr[FAST MODE, FAST MODE], rate = 1
SAMSUNG KLUEG8UHDB-C2D1 0400
```

All six UFS logical units enumerated and the postmarketOS root filesystem was
mounted read-write from `/dev/loop1`.

## Failure

No module-specific state or register marker was printed. The first operation,
`ufshcd_hold(hba, false)`, attempted to leave hibern8 and timed out after about
500 ms:

```text
346.441922 hotdog_r6_ufs_regdump: loading out-of-tree module taints kernel
346.943811 pwr ctrl cmd 0x18 with mode 0x0 completion timeout
346.943845 Device power mode=2, UIC link state=2
346.943856 Auto BKOPS=0, Host self-block=1
346.943862 Clk gate=1, hibern8 on idle=4
346.953892 ufshcd_uic_hibern8_exit: hibern8 exit failed. ret = -110
```

The timeout handler emitted a useful bounded snapshot before recovery:

```text
Host capabilities=0x1587031f, caps=0x18f
ufshcd_print_pwr_info: gear=[1, 1], lane[2, 2],
                       pwr[FAST MODE, FAST MODE], rate = 1
hba->ufs_version = 0x300
core_clk=37500000
core_clk_unipro=37500000
core_clk_ice=37500000
```

The Gear 1 values describe the clock-gated failure boundary, not the normal
Gear 4 operating state recorded during boot.

Vendor recovery then attempted link startup five times, failed, and reached a
kernel `BUG` at `drivers/scsi/ufs/ufshcd.c:7989`. Runtime resume repeated the
same sequence and reached a second `BUG`. The loading task remained in `D`
state:

```text
flush_work
ufshcd_hold
init_module [hotdog_r6_ufs_regdump]
do_one_initcall
do_init_module
load_module
```

At the final observation, USB networking, ping, SSH, `/sys/block/sda/size`, and
the SCSI host remained visible, but the module was still marked `Loading` and
the UFS session could no longer be considered healthy. No `rmmod`, forced task
termination, software reboot, Sahara reset, or automatic device reset was
issued.

## Consequences

1. The original module binary is quarantined and must never be loaded again.
2. The checked-in module source now returns `-EPERM` before device lookup.
3. Existing R6 boot logs and the timeout dump provide the current downstream
   comparison baseline.
4. Any additional downstream register measurement must be instrumented in the
   driver's already-active boot path in a disposable diagnostic kernel. It
   must not wake or reconfigure a healthy rescue session.
5. D16 remains a direct-mainline test, but no longer waits for another live R6
   register probe.
