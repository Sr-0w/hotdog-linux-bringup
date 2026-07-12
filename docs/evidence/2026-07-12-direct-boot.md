# Evidence: 2026-07-12 persistent direct-boot cycles

This page records the persistent `boot_b` direct-boot controls run on
2026-07-12. Device serial values, private logs, credentials, and workstation
paths are intentionally omitted.

## R5 recovery baseline

The R5 no-paint downstream bridge has SHA256
`23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50`.
Starting from fastboot, it produced a fresh SSH boot on
`4.14.357-openela-perf`; the new boot ID, slot-B command-line marker, and
configured device-serial marker were all attested before a candidate write.

R5 was restored after each candidate cycle. Each restoration was followed by
a fresh downstream SSH boot and a later `boot_b` readback with the exact R5
SHA256 above. The host rescue watchers were then stopped cleanly. These checks
validate the tested rollback path; they do not generalize to another device or
partition layout.

## D1 and D1-pack results

Host wall-clock times below are Europe/Brussels time (UTC+02:00).

| Candidate | Persistently written AVB image | USB timeline | Result |
|---|---|---|---|
| D1, Android header v2 with a separate DTB | `f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994` | Downstream USB disconnected at `13:27:38`; fastboot `18d1:d00d` appeared at `13:27:41` | The image write and pre-reboot `boot_b` readback matched exactly. No accepted mainline boot was observed. |
| D1-pack, header v2 with the transformed DTB replacing pack entry 12 | `2f3bf9b7cde3b2d48a3cf4d6fe2fb2f92e210e1a6b1249505fa15be10c26b754` | Downstream USB disconnected at `13:36:16`; fastboot `18d1:d00d` appeared at `13:36:20` | The image write and pre-reboot `boot_b` readback matched exactly. No accepted mainline boot was observed. |

Neither cycle exposed a USB device with mainline `bcdDevice=0617`, an ACM or
NCM interface, or a `900e` identifier. Both returned to real fastboot USB in
approximately three to four seconds. Replacing DTB-pack entry 12 is therefore
not sufficient to make this payload direct-boot on the tested handset.

These observations do not identify the exact failure boundary. In particular,
they do not prove whether control stopped in the bootloader handoff or during
the earliest kernel execution.

## D2 result

D2 retained the exact D1 kernel, DTB,
ramdisk, and command line while changing only the Android boot-image handoff
from header version 2 with a separate DTB section to header version 0 with the
DTB appended to the kernel payload.

| D2 item | SHA256 |
|---|---|
| AVB image | `2076c16598a63bfcfea416b47789eacf74086e33919c0715949cd42719f9b71e` |
| Raw image | `c7c07a0cbf1311395343135253a10b555381f97ff32509c77257fc7b3aee3614` |
| Appended kernel-DTB payload | `9fa9e318cf9d1efea349028a4c1e80b8477fd4839d7a73d3efdc0a0e5811bd09` |
| Linux Image | `48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83` |
| Transformed hotdog DTB | `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440` |
| Wrapped initramfs | `b7e939614b7cb34ecdd8639613d76b8adba39b069b6591e35c39bc4c57a37622` |

The pinned launcher is
[`test-mainline617-direct-d2-header0.sh`](../../scripts/test-mainline617-direct-d2-header0.sh).
D2 was written to `boot_b` and read back exactly before reboot. It returned to
fastboot without an accepted mainline USB identity, matching the D1 result
class. R5 was then restored and verified by fresh downstream SSH and exact
`boot_b` readback. The tested Android header version and appended-DTB handoff
therefore do not explain the direct-boot failure.

## D3 DTBO result

The stock DTBO image contains ten entries. Entry 5 applies successfully to the
downstream DTB used by R5, but applying it to the K1 DTB fails with
`FDT_ERR_NOTFOUND`. D3 preserves the DTBO table, entry identifiers, offsets,
padding, and image size while replacing only entry 5 with a valid no-op
overlay. Applying the replacement to K1 produces a byte-identical K1 DTB.

| D3 item | SHA256 |
|---|---|
| No-op candidate `dtbo_b` | `339e55adaf591f114d8a39a86cb0a0e664e26bc7c7b7f2227e0bee794d10c5fb` |
| Original restore `dtbo_b` | `95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672` |
| Unchanged D1 `boot_b` | `f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994` |
| R5 restore `boot_b` | `23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50` |

The pinned launcher is
[`test-mainline617-direct-d3-dtbo-noop.sh`](../../scripts/test-mainline617-direct-d3-dtbo-noop.sh).
The public
[`build-d3-noop-dtbo.sh`](../../scripts/build-d3-noop-dtbo.sh) builder
reconstructs the candidate from the exact stock dump and K1 DTB and refuses
inputs or output that differ from the recorded hashes.
It holds one phone-operation lock across the R5-to-fastboot handoff and writes
candidate `dtbo_b` before D1 `boot_b`. Two independently attested rescue
watchers restore original `dtbo_b` before R5 `boot_b`.

D3 was run on hardware. Fastboot accepted both candidate writes and returned
3.84 seconds after the raw host USB disconnect, without an accepted mainline
SSH, ACM, NCM, or USB identity. The script reported the state later because it
first re-attested both rescue watchers; that delay is not target boot time.
Rollback restored original `dtbo_b` first and R5 `boot_b` second. A fresh R5
boot produced `4.14.357-openela-perf`; full `dtbo_b` readback matched
`95a111...`, and the exact 61,808,640-byte R5 `boot_b` prefix matched
`23fa53...`. No pstore record was present after rollback.

## Prepared D3-wdt control

D3-wdt keeps the D3 no-op DTBO, transformed DTB, ramdisk, command line, AVB
policy, and rollback images, but substitutes the watchdog debug kernel.

| D1-wdt item | SHA256 |
|---|---|
| AVB image | `74ab6d70f54257399d6b3afe59eaba337a67fc2254355341e2cba52fd769627d` |
| Raw image | `c5b31bc45096705a16255efe059306368de97570cf2e385c6187227e346e4580` |
| Linux Image | `c1d19855e75dd1cfa7ab8e6dd21c0751b6c6f79b5bc588b6c4f5fa7d8d42941e` |
| Transformed hotdog DTB | `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440` |
| Wrapped initramfs | `b7e939614b7cb34ecdd8639613d76b8adba39b069b6591e35c39bc4c57a37622` |

The debug kernel uses `CONFIG_QCOM_WDT=y` and
`CONFIG_WATCHDOG_SYSFS=y`. The pinned launcher is
[`test-mainline617-direct-d3-wdt.sh`](../../scripts/test-mainline617-direct-d3-wdt.sh).
D3-wdt was run and returned to fastboot after the same approximately 3.84-second
raw USB interval as D3. Original `dtbo_b` and R5 `boot_b` were restored and read back
exactly; pstore remained empty. Built-in watchdog initialization therefore did
not change the observed failure boundary.

## Prepared D4 primary-entry probe

D4 keeps the D3 no-op DTBO and exact D1 ramdisk, DTB, command line, header, and
AVB policy. Its kernel calls PSCI `SYSTEM_RESET` as the first operation in
`primary_entry`. D4 produced the same 3.84-second raw USB interval and one slot
retry decrement as D3. It therefore supplied no positive proof that
`primary_entry` was reached. The pinned AVB image is
`06fe64e230f3b09f693d81500bd92a207badda8309e71375f77695a95b094607`.

## Offline validation

The pinned D2, D3, and D3-wdt launchers retain the attested-source checks, fail-closed
hash checks, prearmed R5 rescue watcher, minimum observation window, mainline
kernel and command-line acceptance criteria, and non-success classification for
a restored 4.14 bridge.

The offline safety suite
[`test-d1-safety-offline.sh`](../../scripts/test-d1-safety-offline.sh) passes
all 39 checks. The current-candidate validator
[`validate-current-candidates.sh`](../../scripts/validate-current-candidates.sh)
also passes with D2, D3, and D1-wdt included.
