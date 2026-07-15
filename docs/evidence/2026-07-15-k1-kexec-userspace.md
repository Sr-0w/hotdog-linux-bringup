# K1 mainline userspace evidence (2026-07-15)

This run validated the historical K1 Linux 6.17 payload as a complete kernel
and postmarketOS userspace combination. It also separated that result from the
still-failing direct boot path.

## Validated kexec boot

R6 Linux 4.14 booted from slot B and provided the controlled kexec bridge. The
bridge reported the APSS watchdog disabled before handoff. The K1 Image was
modified only to clear the same watchdog enable register in `primary_entry`.

| Item | Value |
|---|---|
| Kernel commit | `379d8fe35c7ca685a650bd82fd023af0ea3f0de0` |
| Runtime identity | `6.17.0-sm8150-g379d8fe35c7c-dirty` |
| Kernel Image SHA256 | `d0eb811216e5e61c682ea5e0597d393151803cfa5e8af0f09d35b0fc70b124c3` |
| DTB SHA256 | `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440` |
| Initramfs SHA256 | `b7e939614b7cb34ecdd8639613d76b8adba39b069b6591e35c39bc4c57a37622` |
| Mainline boot ID | `0d710588-58c8-4d59-96ba-04ec8ef05246` |

SSH became reachable at `172.16.42.1`. The system remained stable for the
observation window and exposed all eight CPUs, Samsung UFS storage, the nested
postmarketOS root filesystem, USB NCM, USB ACM, and OpenSSH.

The same run also recorded the current hardware gaps:

- Apps SMMU registration times out with `-ETIMEDOUT`.
- No DRM framebuffer or connector is registered.
- Touch input is absent.
- The temporary device tree exposes only the reduced bring-up memory map.
- Wi-Fi, Bluetooth, audio, modem, cameras, and charging remain unvalidated.

The validated launch path is `scripts/test-mainline-via-kexec.sh`. Its fallback
watchdog helper is built reproducibly by
`scripts/build-hotdog-apss-wdt-control.sh` from the tracked helper source.

## Direct-boot follow-up

A direct candidate then used the same K1 commit and postmarketOS payload with
the already validated temporary direct-boot workarounds:

- stock-compatible non-EFI arm64 Image entry layout;
- forced single-CPU bring-up;
- `CONFIG_RAID6_PQ_BENCHMARK=n`;
- early APSS watchdog disable;
- D7 UFS/GDSC bridge DTBO.

| Item | Value |
|---|---|
| Kernel Image SHA256 | `ddc716c5b8be880bca52d46d2074a5b0ea104875b9a8aa040528144f422e8483` |
| AVB boot image SHA256 | `38c103f9cc03cc7f0f90033cf29b658e42d73486e0875f24f6dd815ecd7d7ffe` |
| Observation window | 480 seconds |
| Result | Fixed OnePlus logo; no USB identity and no SSH |

This proves that bypassing the RAID6 benchmark is necessary but not sufficient
for a complete direct boot. The remaining failure is specific to the direct
firmware-to-kernel handoff or a later direct-only initialization dependency;
the complete K1 kernel and userspace are viable after the downstream bridge.

## Direct-boot watchdog diagnostic

The first follow-up writes a persistent breadcrumb before and after every
initcall, writes the downstream OnePlus fastboot restart reason to IMEM, and
arms the APSS watchdog. If an initcall stalls, the next warm reset should retain
the last stage. The watchdog and breadcrumb were hardware-tested; the IMEM
restart reason did not select fastboot and the device entered Qualcomm
Crashdump instead.

The complete experimental source delta is tracked as
[`experimental-mainline-autorescue-breadcrumb.patch`](../../patches/experimental-mainline-autorescue-breadcrumb.patch).
It applies directly to K1 commit
`379d8fe35c7ca685a650bd82fd023af0ea3f0de0` and includes the temporary Android
entry layout, forced single-CPU bring-up, FTS prototype correction, and the
watchdog/breadcrumb instrumentation.

| Reproduction item | SHA256 |
|---|---|
| Hardware-tested patch snapshot | `82982736ffd52690cc747887e1bfd5de416a30d804b96efa6947171396fde9b2` |
| Hardware-tested early-stage patch | `86891ac59e252a8aa0fd9976be313ee5b4235d329eab28ee3adac64900057c08` |
| Current tracked diagnostic patch | `fc260de080e3e769dfa570ca634bd6e55eedaf3f7cd943158636aa0041120206` |
| Final `.config` | `03e6c62565ebb2c743204086b2cfb058ee4b7f1ea6d0773bb67ff022d5cbb561` |
| Original prepared Image | `80c9a8457661aad5bb3d4354462cdb76a212f94fb9e4fd946f73c68a65e16261` |
| Clean rebuild Image with a fresh CPIO | `4354cb544eaee32b733d074b39665bb91709b9901ae2c73f00f628555db989ed` |
| Clean relink Image with the original CPIO | `282366e99219f92c960a6146b01489a80555cf69e129ce1bfd17bda003bd9d4e` |
| Prepared AVB boot image | `a4552626e2c4426707937b2d3eedeef8e3f5fcfb1f06f21dafd633fc98605485` |

The clean replay of the hardware-tested snapshot started from the pinned
commit, applied only that patch, copied the tracked K1 package config, enabled
`CONFIG_QCOM_WDT=m`, ran
`make ARCH=arm64 LLVM=1 olddefconfig`, and built with Clang 22.1.8 and LLD
21.1.8. The resulting source files and final config match the prepared
candidate exactly. Recreating the original CPIO byte-for-byte and relinking
produced the second clean-replay hash above. It still differs from the original
candidate because that candidate came from an incremental thin-archive build;
the archive retains source-path-prefixed member names that can affect linker
tie ordering. The original Image is therefore recorded as an experimental
artifact, not claimed as a byte-for-byte clean-build output.

### Hardware result

The prepared AVB image was written to `boot_b` with the D7 DTBO after a fresh,
identity-checked R6 boot. The APSS watchdog reset the phone into Qualcomm
Crashdump (`05c6:900e`) rather than fastboot. A direct `SAHARA_RESET_REQ` was
accepted and produced a repeatable physical reboot, but the same candidate
returned to `900e` on the next watchdog expiry.

Sahara memory-debug mode then read only the dedicated breadcrumb page and IMEM
restart reason:

| Field | Observed value |
|---|---|
| Breadcrumb magic | `0x48444f47` (`HDOG`) |
| Breadcrumb stage | `1` (`primary_entry`) |
| Image-resident magic | `0x32454448` (`HDE2`) |
| Image-resident format | version 1 |
| Image-resident stage | `200` (`do_initcalls()` entry) |
| Stage/detail guards | valid |
| IMEM restart reason | `0x77665500` |

The fixed page is initialized in pre-MMU assembly, but its stage-2 update first
depends on `ioremap()` of that normal RAM page. The fixed record remaining at
stage 1 therefore did not prove a pre-initcall failure. The independent,
guarded Image-resident record reached stage 200 immediately before
`hotdog_prepare_initcall_diagnostics()`, proving that direct boot reaches
`do_initcalls()`. This supersedes the earlier pre-initcall interpretation.
Bytes after the fixed stage-1 header remain stale RAM and must not be
interpreted as an initcall index. Reading the APSS watchdog MMIO through Sahara
timed out, so no post-reset register value is claimed.

The boot ROM accepted Sahara command mode but rejected the signed OnePlus
Firehose loader and `SWITCH_TO_DMSS_DLOAD`. The tested `900e` transport can
therefore inspect RAM and reset the SoC, but cannot yet restore partitions or
select fastboot without a physical button cycle. The bounded public interface
for these two validated operations is
[`qualcomm-900e-autorescue.sh`](../../scripts/qualcomm-900e-autorescue.sh).

### Image-resident early-stage result

The next candidate moves the missing diagnostics into an Image-resident
64-byte record that is writable through both the identity and final kernel
mappings. Each stage and detail value has a bitwise-inverse guard, and every
cached write is cleaned to the point of coherency before execution continues.
This candidate was built, AVB-verified, and booted on hardware. It entered
Qualcomm Crashdump after reaching stage 200 with valid stage and detail guards.

| Item | Value |
|---|---|
| Source patch SHA256 | `86891ac59e252a8aa0fd9976be313ee5b4235d329eab28ee3adac64900057c08` |
| Kernel Image SHA256 | `db0368f593d39e0c439e24ec33c2b580bf91b4f87aea0f14475b7afadfe4281b` |
| Raw boot image SHA256 | `fd61e7c0e3b5a809f72a0b6da4e0c34fc31fa50522b0e445abb646d471bdebc2` |
| AVB boot image SHA256 | `567ec0509b24c67677d3c8dcdd729b1ceb3fd6bd020864a4a692b26faa8f4a00` |
| DTB SHA256 | `040b4b50989b01dafe400436137bf73a64f3ad5e89bf4c7ddf79a19b3cfcee4c` |
| Initramfs SHA256 | `b7e939614b7cb34ecdd8639613d76b8adba39b069b6591e35c39bc4c57a37622` |
| Cmdline SHA256 | `e72379faaf011ea3cacca4202a625dc8839ac32187a6b59c8c1784f1d02cc960` |
| Breadcrumb Image offset | `0x1b8f800` |
| Expected physical address | `0x81c0f800` |

The stage map is deliberately coarse but covers every previously invisible
transition:

| Stage | Last completed boundary |
|---:|---|
| 10 | `__cpu_setup()` |
| 20 | immediately before `__enable_mmu()` |
| 30 | immediately after `__enable_mmu()` |
| 40 | `__pi_early_map_kernel()` |
| 50 | entry to `__primary_switched` |
| 60 | immediately before `start_kernel()` |
| 100 | entry to `start_kernel()` |
| 110 | boot CPU identity setup |
| 120 | `setup_arch()` |
| 140 | `mm_core_init()` |
| 150 | `sched_init()` |
| 160 | timer and timekeeping setup |
| 170 | local IRQ enable |
| 180 | `console_init()` |
| 190 | immediately before `rest_init()` |
| 200 | entry to `do_initcalls()` |

The hardware result selected the initcall loop, rather than early arm64 entry,
as the next diagnostic boundary.

### Prepared per-initcall follow-up

The current candidate removes the failed normal-RAM `ioremap()` path. It keeps
the breadcrumb embedded in the Image, adds guarded initcall level and function
address fields, marks each watchdog setup operation, and records every initcall
immediately before and after execution. The APSS watchdog is kicked around each
returning initcall and disarmed only after all levels complete.

| Item | Value |
|---|---|
| Source patch snapshot SHA256 | `dbdde00015965904ca7fcd0b733b8c585fe8eb44729fa3fc90dbcc6ac8003b66` |
| Final `.config` SHA256 | `03e6c62565ebb2c743204086b2cfb058ee4b7f1ea6d0773bb67ff022d5cbb561` |
| Breadcrumb format | version 2 |
| Kernel Image SHA256 | `e372480a634412f0f9ab150eff48b5a8cf5eff7691eaf70b3013b4c0dee60051` |
| Raw boot image SHA256 | `1e311adffc7866372f9d64754cd1ff8b79a00825fc11b0e629744eaba7c4869b` |
| AVB boot image SHA256 | `94c9898b636b8035a5f7de8f36379b9c833064dd5201d744108a0f4bcf23e5cc` |
| DTB SHA256 | `040b4b50989b01dafe400436137bf73a64f3ad5e89bf4c7ddf79a19b3cfcee4c` |
| Initramfs SHA256 | `b7e939614b7cb34ecdd8639613d76b8adba39b069b6591e35c39bc4c57a37622` |
| Cmdline SHA256 | `e72379faaf011ea3cacca4202a625dc8839ac32187a6b59c8c1784f1d02cc960` |
| Breadcrumb Image offset | `0x1b8f800` |
| Expected physical address | `0x81c0f800` |

| Stage | Meaning |
|---:|---|
| 201 | entered diagnostic watchdog preparation |
| 202 | IMEM restart-reason mapping returned; detail is mapping success |
| 203 | APSS watchdog mapping returned; detail is mapping success |
| 204 | watchdog programming completed |
| 300 | immediately before an initcall |
| 301 | immediately after the same initcall returned |
| 400 | all initcall levels completed and watchdog disarm started |

For stages 300 and 301, `detail` is the global initcall index, `level` is the
kernel initcall level, and `initcall_address` is the full virtual function
address. Stage, detail, level, and address all carry inverse guards so a torn
write can be rejected before resolving the address against the matching
`vmlinux`.

### Per-initcall hardware result

The format-v2 candidate entered Qualcomm Crashdump with every guard valid and
the following last record:

| Field | Value |
|---|---|
| Stage | `300` (before initcall) |
| Global index | `524` |
| Initcall level | `6` |
| Runtime function address | `0xffffffc0817ff264` |
| Link-time function address | `0xffffffc08177f264` |
| KASLR slide | `0x80000` |
| Resolved symbol | `calibrate_xor_blocks` in `crypto/xor.c` |

The PREL32 entry is level-6 local index 108 at link address
`0xffffffc081827f34`. Its signed offset resolves to
`calibrate_xor_blocks()`. That function enters `do_xor_speed()`, which waits
for `ktime_get()` to advance before measuring throughput. This is the second
time-based boot calibration to block after the RAID6 benchmark, so the common
direct-boot timer path is now the primary root-cause target.

### Command-line XOR-calibration bypass

The next diagnostic image changes only the existing `initcall_blacklist`
command-line value by appending `calibrate_xor_blocks`. Kernel, DTB, initramfs,
watchdog, and format-v2 per-initcall instrumentation are unchanged.

| Item | Value |
|---|---|
| Kernel Image SHA256 | `e372480a634412f0f9ab150eff48b5a8cf5eff7691eaf70b3013b4c0dee60051` |
| Cmdline SHA256 | `e4e36d4a0f4378905d1836675146e761cef2881f595a6afa6cf4ea02125aa1d8` |
| Raw boot image SHA256 | `0f1d8fe2001c247d69e74dc7948552b25d1d17e736a800c662ac8e3d8783b6b7` |
| AVB boot image SHA256 | `ac80f1ece46ad0363de94950f27788ed9b40c8c19d83c84b5ecfbfc6a1249a18` |
| Breadcrumb physical address | `0x81c0f800` |

Hardware returned the same fully guarded stage-300 record for initcall 524.
The boot image contains the requested token in Android `extra_cmdline`, but the
running direct-boot path did not skip the function. Whether ABL omitted that
field or the runtime blacklist lookup failed is not established; this image is
therefore superseded and is not evidence for either explanation.

### Prepared Kconfig XOR-calibration bypass

The tracked experimental patch now adds `CONFIG_XOR_BLOCKS_BENCHMARK`, enabled
by default. The bring-up config disables it. `calibrate_xor_blocks()` then
retains the first architecture-compatible XOR backend registered by
`register_xor_blocks()` and cannot enter `do_xor_speed()`. The boot image uses
the original command line, so the kernel is the only payload changed from the
format-v2 hardware test.

| Item | Value |
|---|---|
| Source patch snapshot SHA256 | `dbdde00015965904ca7fcd0b733b8c585fe8eb44729fa3fc90dbcc6ac8003b66` |
| Final `.config` SHA256 | `25fbb9ed629241471b32c8390cab039d4da7825cdd60b525691299a2494017c7` |
| Kernel Image SHA256 | `6c42fd0a8fd71c89d66ed399c3a8113f91e98e69e230cdeb68ef96b4de93e453` |
| Cmdline SHA256 | `e72379faaf011ea3cacca4202a625dc8839ac32187a6b59c8c1784f1d02cc960` |
| Raw boot image SHA256 | `a1dd3f84bfe264c1c98a7a78a35feb8304722de211b5ff31985d3c13725b74f5` |
| AVB boot image SHA256 | `fb79f45c8a4e57dc05da5ee66725df568cd1e7981794328f8deac79bf6fc231f` |
| Breadcrumb physical address | `0x81c0f800` |

### Prepared system-counter handoff test

The two independently observed direct-boot stalls wait on different kernel
time interfaces: RAID6 waits on `jiffies`, while XOR waits on `ktime_get()`.
The same Linux 6.17 payload advances normally after kexec. This motivates, but
does not yet prove, the hypothesis that the direct ABL handoff leaves the
SM8150 system counter disabled.

The next candidate sets `CNTCR.EN` at the architected SM8150 control base
`0x17c20000` before enabling the MMU. Breadcrumb format 3 preserves `CNTCR`
and `CNTVCT_EL0` values from immediately before and after that write, while
retaining the guarded per-initcall record. A fixed-iteration delay makes the
counter delta meaningful without depending on the timer being functional.

| Item | Value |
|---|---|
| Source patch SHA256 | `fc260de080e3e769dfa570ca634bd6e55eedaf3f7cd943158636aa0041120206` |
| Final `.config` SHA256 | `25fbb9ed629241471b32c8390cab039d4da7825cdd60b525691299a2494017c7` |
| Kernel Image SHA256 | `9deab9853de910eff797411ac8be07272f09041f7d4d15f638bd6c080858a5c5` |
| Raw boot image SHA256 | `534876896c13530f45491491d6792139aff8c0f1ae11a43b85881f78185e334a` |
| AVB boot image SHA256 | `b1210988b470ae0f8595f035b4d5d7c561b4e5fb18f9158532a93bef86a80f5e` |
| Breadcrumb format | version 3, 80-byte Sahara read |
| Breadcrumb physical address | `0x81c0f800` |

Payload hashes, extracted component comparison, patch reverse-application,
and AVB verification passed. Hardware validation is pending.

If the candidate returns to `900e`, read both records without dumping RAM:

```bash
scripts/qualcomm-900e-autorescue.sh inspect \
  --early-breadcrumb-address 0x81c0f800
```

The physical address must be paired with the selected Image hash. A
firmware-compatible recovery selector is still needed in addition to the
verified APSS watchdog, because the IMEM value alone did not prevent Crashdump
selection.
