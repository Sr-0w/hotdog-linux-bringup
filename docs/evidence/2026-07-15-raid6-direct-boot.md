# RAID6 direct-boot checkpoint evidence (2026-07-15)

This run tested the first direct-boot blocker isolated by the D39-D50
checkpoint series. The candidate kept RAID6 enabled and disabled only its
implementation benchmark.

## Candidate

| Item | Value |
|---|---|
| Kernel base | Linux 6.17 SM8150 K1 source |
| Kernel config delta | `CONFIG_RAID6_PQ=y`, `CONFIG_RAID6_PQ_BENCHMARK=n` |
| Checkpoint | Reset after `subsys` entry 49 |
| Boot image | `2026-07-15-083100-mainline617-direct-raid6-nobench-after49-r6ramoops/boot.img` |
| Boot image SHA256 | `84a695942b0aaec44f7a0a53dea0afc5a4a4ac7432bc9cbc796165883d42ab8d` |
| Kernel Image SHA256 | `0a7a21fa230c2facc98955b3f55b8f3ee29bbbd74c4f7c06942ea47fadee503a` |
| Candidate DTBO SHA256 | `c7b22d3c2b8d9d09d95ee9ef8f3ead91dae2d7ec85e259c03b44bc3b2afa8978` |

AVB verification and extracted kernel/DTB comparison completed before the
hardware run. The source environment was R6 on slot B, kernel
`4.14.357-openela-perf`, boot ID
`6732c3dd-7fe5-4351-8692-d9635a5c8438`.

## Observation

The transaction flashed the candidate DTBO and boot image to slot B and
rebooted at `09:07:46` local time. At `09:08:31`, USB re-enumerated as the R6
postmarketOS NCM plus ACM gadget (`18d1:d001`, `bcdDevice=4.14`). This proves
that the mainline checkpoint reset fired rather than holding at the fixed
OnePlus logo as the benchmark-enabled after-49 control had done.

ABL selected slot A after the checkpoint reset. USB ACM and later SSH confirmed
R6/A with boot ID `725fe557-6621-4774-b591-15b77a157d90`. The ramoops mount was
present but contained no pstore record.

The host requested `RESTART2(bootloader)` from R6/A. Fastboot appeared without
physical input, and the prearmed watcher restored the pinned R6 image and stock
DTBO to slot B, selected B, and rebooted. R6/B reached SSH with boot ID
`c79da670-bfca-49a6-903f-494ce356cc66`.

## Restore verification

| Partition | Verification |
|---|---|
| `boot_b` | First `61,808,640` bytes match R6 SHA256 `e76c85a56cdbcc6ddd105844eb322cb854fb33b2b23077da12ff098adc8f2369` |
| `dtbo_b` | Full partition matches stock SHA256 `95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672` |
| Active slot | R6 cmdline reports `androidboot.slot_suffix=_b` |

Fastboot does not zero the unused tail of `boot_b`, so verification correctly
compares the complete image-length prefix rather than hashing the full
96 MiB partition against the shorter image file.

## Conclusion

`raid6_select_algo` returns on this direct single-CPU path when
`CONFIG_RAID6_PQ_BENCHMARK` is disabled. The benchmark waits for `jiffies` to
advance while preemption is disabled; the result is compatible with an early
timer-tick problem, but does not independently prove that root cause.

The configuration workaround is hardware-validated. A normal direct mainline
userspace boot and the complete r5 package payload remain separate validation
targets.
