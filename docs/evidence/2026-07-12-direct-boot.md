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

## Prepared D2 control

D2 is the next prepared hardware control. It retains the exact D1 kernel, DTB,
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
D2 is prepared and validated offline; no D2 hardware result is claimed.

## Prepared watchdog control

D1-wdt is ordered after D2. It keeps the D1 header-v2 layout, transformed DTB,
ramdisk, command line, AVB policy, and rollback image, but substitutes the
watchdog debug kernel.

| D1-wdt item | SHA256 |
|---|---|
| AVB image | `74ab6d70f54257399d6b3afe59eaba337a67fc2254355341e2cba52fd769627d` |
| Raw image | `c5b31bc45096705a16255efe059306368de97570cf2e385c6187227e346e4580` |
| Linux Image | `c1d19855e75dd1cfa7ab8e6dd21c0751b6c6f79b5bc588b6c4f5fa7d8d42941e` |
| Transformed hotdog DTB | `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440` |
| Wrapped initramfs | `b7e939614b7cb34ecdd8639613d76b8adba39b069b6591e35c39bc4c57a37622` |

The debug kernel uses `CONFIG_QCOM_WDT=y` and
`CONFIG_WATCHDOG_SYSFS=y`. The pinned launcher is
[`test-mainline617-direct-d1-wdt.sh`](../../scripts/test-mainline617-direct-d1-wdt.sh).
No D1-wdt hardware result is claimed. Watchdog initialization remains a
secondary hypothesis, not an established cause: D1 and D1-pack returned to
fastboot USB within only three to four seconds.

## Offline validation

The pinned D2 and D1-wdt launchers retain the attested-source checks, fail-closed
hash checks, prearmed R5 rescue watcher, minimum observation window, mainline
kernel and command-line acceptance criteria, and non-success classification for
a restored 4.14 bridge.

The offline safety suite
[`test-d1-safety-offline.sh`](../../scripts/test-d1-safety-offline.sh) passes
all 30 checks. The current-candidate validator
[`validate-current-candidates.sh`](../../scripts/validate-current-candidates.sh)
also passes with D2 and D1-wdt included.
