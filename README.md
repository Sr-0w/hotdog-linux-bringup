# Linux on the OnePlus 7T Pro (`hotdog`)

Experimental Linux and postmarketOS bring-up for the OnePlus 7T Pro. The
physical test handset is rear-labelled as a European HD1913 with a Qualcomm
Snapdragon 855+ (SM8150-AC), while its recovery and vendor software identify
it as HD1911 and expose the `hotdog` project/codename.

> [!WARNING]
> This is early hardware enablement, not a daily-driver image. An unlocked
> bootloader and a dedicated test device are strongly recommended. A failed
> kernel can leave the phone unreachable until fastboot or recovery returns.

## Project status

Linux 6.17 reaches the installed postmarketOS root filesystem on real hardware
through the validated downstream 4.14 kexec bridge. A persistent image launched
directly by the OnePlus bootloader now completes kernel initialization, executes
PID 1 from the initramfs, sustains EL0 syscalls, and reaches the first
postmarketOS stage-two init. It currently stalls inside `setup_udev`. Direct
rootfs and USB access remain under active bring-up. Repeat runs exposed two
timeout overflows after all 986 initcalls: first in the early kernel watchdog,
then in the PID 1 fallback. The corrected image disables the former before its
final breadcrumb and reaches PID 1 with hardware-safe 32-second intervals.
The periodic PID 1 watchdog did not produce a host-visible Fastboot return at
its logical deadline. A standalone static supervisor then replaced that shell
worker, used a monotonic deadline, issued `RESTART2(bootloader)` itself, and
kept a 32-second APSS fallback armed. The hardware test still did not return to
host-visible Fastboot. The same run reached the static-supervisor return and
then stalled inside `setup_udev`. A new static fork/exec helper now bounds each
udev command independently without relying on BusyBox ash background-job
behavior. Its build, timeout behavior, and initramfs integration are validated
offline; hardware validation is next.

| Component | Status | Notes |
|---|---|---|
| Mainline kernel entry | Working | Linux `6.17.0-sm8150` starts through the downstream kexec bridge. |
| UFS storage | Working | Samsung UFS and the complete partition table are detected. |
| postmarketOS rootfs | Working | The nested `pmOS_root` filesystem mounts read-write. |
| USB networking | Working | NCM gadget, host address `172.16.42.2`, device address `172.16.42.1`. |
| SSH | Working | OpenSSH starts from the real postmarketOS userspace. |
| USB serial | Working | ACM console is exposed on `ttyGS0`. |
| Mainline reboot | Working in the validated kexec environment | A mainline boot with PM8150 PON `mode-bootloader = <2>` returned directly to fastboot through `RESTART2(bootloader)`. A separate pre-MMU APSS watchdog probe also produced a physical reset during direct boot. Integration into the publishable kernel and DTB remains pending. |
| K1 package | Current r5 build evidence, package hardware test pending | One strict pmbootstrap build produced a `27,172,103`-byte r5 APK, SHA256 `f3083fd4c6af13be364eb0317873ee3a6f3690c5acb3a9e111c65b26b1746dd6`. Its embedded config keeps `CONFIG_RAID6_PQ=y`, disables `CONFIG_RAID6_PQ_BENCHMARK`, and uses `CONFIG_QCOM_WDT=y`. |
| Persistent direct mainline | Active stage-two userspace | Direct boot completes `kernel_init_freeable()`, returns from the async initramfs wait, succeeds in `kernel_execve()`, crosses EL1 to EL0, executes more than 16 PID 1 syscalls, enters `init_2nd.sh`, and reaches `setup_udev`. The tested stage-two image did not return from that function, and no direct-boot USB identity or mounted rootfs has been observed yet. |
| Firmware packaging | Complete, runtime unvalidated | The `20241212-r0` split produces eight usrmerged APKs with all payloads under `/usr/lib/firmware`; peripheral runtime support remains pending. |
| Early display output | Working for diagnostics | Direct pre-MMU, post-MMU, post-init, EL0-transition, and PID 1 syscall markers are visible over the retained OnePlus splash. A normal mainline DRM console is not available yet. |
| Mainline panel | Not working | The panel becomes black after early boot; the DRM path is not enabled. |
| RAM | Partial | Only about 448 MiB is currently exposed. |
| Touch, Wi-Fi, Bluetooth, audio, modem, cameras | Not validated | These remain bring-up work. |

See [docs/status.md](docs/status.md) for the detailed support matrix.

## Validated boot path

```mermaid
flowchart LR
    A["OnePlus bootloader"] --> B["Downstream 4.14 bridge in boot_b"]
    B --> C["kexec Linux 6.17 + hotdog DTB"]
    C --> D["Wrapped postmarketOS initramfs"]
    D --> E["UFS and nested GPT discovery"]
    E --> F["postmarketOS rootfs"]
    F --> G["OpenRC, USB NCM, ACM and SSH"]
```

The bridge is a temporary engineering tool. The long-term target is a normal
postmarketOS/pmaports boot that does not depend on the downstream kernel.

The tested OnePlus ABL does not provide a dependable unattended fallback to a
known-good A slot: after slot B reached retry count zero, firmware kept B active
and displayed the red failure screen instead of selecting successful slot A.
The PM8150 PON bootloader reason works from a mainline kexec boot, but D46-D48
did not make it a dependable pre-MMU recovery path. Current direct-boot tests
therefore keep a verified R6 restore image, place one candidate on slot B, and
classify the result from the display. The tested bounded-udev candidate armed
the APSS watchdog from PID 1 with the bootloader restart reason. That hardware
test reached the postmarketOS stage-two handoff, but its shell worker did not
return the phone to Fastboot after the logical deadline. The prepared follow-up
used the standalone static supervisor described above, reached
`setup_udev`, and likewise failed to expose Fastboot after the deadline. The
current candidate moves each potentially blocked udev launch into a static
fork/exec helper with a monotonic 15-second timeout. A detached host supervisor
still restores and verifies R6 whenever Fastboot becomes visible.

D39 was reproduced unchanged with the original R6/B transaction, seven slot
retries, and a fixed logo for 90 seconds. Rebased D40 changes only the checkpoint
from entry 69 to entry 66 and also held at the fixed logo for 110 seconds. D41
changes only the checkpoint to entry 33; it reset repeatedly, exhausted the
slot-B attempts, and selected the working R6 image on slot A. The valid
unresolved range was therefore `subsys` entries 34-66. D42 held at the fixed
logo and did not reach its checkpoint after entry 49, narrowing that range to
entries 34-49. D43 reached its checkpoint after entry 41 and automatically
fell back to R6 on slot A, narrowing the range to entries 42-49. The search now
advances sequentially: D44 also reached its checkpoint after entry 42 and
returned through R6/A. D45, D46, and D47 then reached entries 43, 44, and 45.
D47 and D48 were restored directly to R6/B by the prearmed watcher, proving
entries 45 and 46 return. D49 then fell back to R6/A after entry 47 and was
recovered through software fastboot. D50 then proved entry 48 returns. Combined
with D42, this isolates entry 49, `raid6_select_algo`. A supervised follow-up
kept `CONFIG_RAID6_PQ=y`, disabled only `CONFIG_RAID6_PQ_BENCHMARK`, reached
the checkpoint after entry 49, and reset into R6/A. R6/B plus the stock DTBO
were then restored and read back exactly. The workaround is validated; the
underlying early timer behavior still needs diagnosis. A subsequent direct
candidate removed the checkpoint, retained the single-CPU and no-benchmark
workarounds, and added the entry-time watchdog clear that is stable through
kexec. It still held the fixed OnePlus logo for 480 seconds without USB or
SSH, proving that another direct-only blocker remains after the RAID6 fix.
The intervening one-try experiments are superseded because they
reached the red failure screen with slot B already at retry count zero and do
not prove checkpoint execution.

The direct-entry trace no longer depends on slot retry behavior or a working
kernel console. It first proved the MMU transition, `start_kernel()`, and
`paging_init()`. A later failure was traced to retaining an `early_memremap()`
pointer after `early_ioremap_reset()`. Replacing that pointer with the normal
arm64 linear mapping after `paging_init()` exposed the complete post-init row:
the global async wait returned, init memory was released, `kernel_execve()`
succeeded, and all three EL1-to-EL0 transition markers appeared. A PID 1-only
syscall row then showed a first syscall entry and return, a second syscall, and
at least 16 total syscalls.

That PID 1 trace also exposed an Android boot-image contract issue. The tested
HD1913 bootloader ignores header-v2 `extra_cmdline` and copies only 511
characters from the primary 512-byte field. The diagnostic `rdinit=` token had
been stored beyond that boundary, so Linux correctly ran the original
postmarketOS `/init` instead of the static wrapper. The direct-image builder now
rejects longer command lines, and the next hash-pinned candidate places every
boot-critical token in the accepted field. Exact hashes and marker meanings are
recorded in the
[2026-07-30 direct PID 1 evidence](docs/evidence/2026-07-30-direct-pid1.md).

Persistent `boot_b` testing on 2026-07-12 established a working R5 rescue
baseline and three negative mainline handoff results. D1 AVB
`f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994`
and D1-pack AVB
`2f3bf9b7cde3b2d48a3cf4d6fe2fb2f92e210e1a6b1249505fa15be10c26b754`
plus D2 header-v0 AVB
`2076c16598a63bfcfea416b47789eacf74086e33919c0715949cd42719f9b71e`
were each written and read back exactly before reboot, then returned to real
fastboot USB without an observed mainline USB identity. R5 was restored and
verified after each cycle. These controls exclude the tested boot-header and
DTB-placement variants, but do not identify the exact early failure boundary.

Offline overlay analysis found that the stock `dtbo_b` entry selected for this
hardware applies to the downstream DTB but fails against the K1 DTB with
`FDT_ERR_NOTFOUND`. D3 preserved the DTBO table and replaced only that overlay
with a no-op while booting unchanged D1. Raw host USB shows fastboot returning
3.84 seconds after disconnect, matching D1/D2. Its rollback restored and read
back original `dtbo_b` before exact R5 `boot_b`. D3-wdt and D4-entry produced
the same interval. The R5 control then proved the no-op DTBO itself is not a
valid baseline. D5 retained 56 fragments and applied cleanly to both DTBs; R5
reached its telnet initramfs but failed to mount the nested filesystems. D6
added K1 aliases for the vendor UFS symbols, retained 58 fragments, exposed all
UFS LUNs and USB ACM, then stalled during `pmos_continue_boot`; a repeat entered
Qualcomm `900e` crashdump mode. D7 retains the complete vendor UFS fragments
through an always-on fixed-regulator bridge for `ufs_phy_gdsc`. With unchanged
R5 it reached a fresh SSH boot on hardware, and strict readback confirmed the
R5 boot image plus D7 DTBO exactly. D8 then returned to fastboot after about
26 seconds; offline replay proved its embedded DTB could not accept D7. D9
embeds the corrected bridged DTB. The rollback environment is now R6 with the
stock DTBO: it reached fresh SSH with `watchdog_v2.enable=0`, and strict
readback matched both images exactly. See the
[2026-07-12 direct-boot evidence](docs/evidence/2026-07-12-direct-boot.md) and
[2026-07-15 RAID6 checkpoint evidence](docs/evidence/2026-07-15-raid6-direct-boot.md),
the [K1 userspace evidence](docs/evidence/2026-07-15-k1-kexec-userspace.md),
plus the [controlled test matrix](docs/direct-boot.md).

## Mainline fixes validated so far

The successful boot is not a stock mainline device tree. It currently applies
the following bring-up changes:

1. Reserve the firmware-owned `0x89d00000-0x8b700000` memory gap as `no-map`.
2. Temporarily remove `iommus` from UFS and QUP clients because the Apps SMMU
   registration fails with `-EINVAL`.
3. Remove the UFS `qcom,ice` link so UFS can probe without the failing ICE
   clock path.
4. Remove the DWC3 `iommus` link so the USB gadget does not remain deferred
   behind the failed Apps SMMU.
5. Boot with `iommu.passthrough=1 arm-smmu.disable_bypass=0`.
6. Wait 120 seconds before the normal postmarketOS initramfs path. A 15-second
   delay was tested and is insufficient.
7. Keep the framebuffer probe in wait-only mode for its timing effect while
   removing all red/green/blue framebuffer writes from the downstream 4.14
   userspace probe; those RGB frames were not emitted by mainline.
8. Discover the postmarketOS GPT nested inside the Android `super` partition
   and expose its boot and root filesystems through loop devices.
9. Capture the short-lived USB ACM console with host echo disabled so the
   collector does not feed bytes back into the target during early boot.
10. In the historical K1 configuration, load the matching `qcom-wdt.ko` after
    userspace comes up when a restart-handler probe is required. The current r5
    package instead builds this driver into the kernel and remains
    hardware-untested as a complete package payload.
11. Keep RAID6 enabled but disable `CONFIG_RAID6_PQ_BENCHMARK`. The benchmark
    waits for `jiffies` to advance and blocked the forced-single-CPU direct path;
    the no-benchmark candidate reached the next checkpoint on hardware.
12. Clear the APSS watchdog enable register in `primary_entry` for the K1 kexec
    payload. This exact Image reached postmarketOS SSH and remained stable; the
    direct candidate using the same clear still encountered a later blocker.
13. Release the diagnostic `early_memremap()` mapping before
    `early_ioremap_reset()` and use `phys_to_virt()` only after `paging_init()`.
    This is a diagnostic framebuffer lifetime fix, not a proposed display
    driver.
14. Keep direct-boot command lines at 511 characters or fewer. The tested ABL
    drops byte 512 and ignores the header-v2 `extra_cmdline` field.

These are bring-up fixes, not proposed upstream solutions. The SMMU bypasses,
ICE removal, reduced memory map, and timing waits all need proper replacements.
The technical evidence and rationale are documented in
[docs/mainline-bringup.md](docs/mainline-bringup.md).

## Getting started

Clone the repository and inspect the host without touching a phone:

```bash
git clone https://github.com/Sr-0w/hotdog-linux-bringup.git
cd hotdog-linux-bringup
./scripts/bootstrap-host.sh
```

Fetch the external source trees:

```bash
./scripts/bootstrap-sources.sh --sm8150-k1
cp pmbootstrap_v3.cfg.example pmbootstrap_v3.cfg
cp hotdog.env.example hotdog.env
./scripts/check-host-tools.sh
./scripts/build-mainline-k1-dtb-chain.sh
```

The repository does not distribute ready-to-flash boot images. Generated
kernels, initramfs archives, phone dumps, logs, and source checkouts stay in
ignored local directories. Follow [docs/host-setup.md](docs/host-setup.md),
[docs/artifacts.md](docs/artifacts.md), and
[docs/device-safety.md](docs/device-safety.md) before any hardware operation.

Once the hash-pinned artifacts have been built or restored, the complete
mainline cycle is launched with:

```bash
./scripts/test-mainline617-pmos-full.sh
```

That launcher hash-checks the kernel, DTB, initramfs, and restore image before
transferring control to mainline.

The complete K1 DTB chain is reproducible from a clean source checkout and
tracked inputs. The launcher remains a lab replay until the kernel, initramfs,
and Android boot image are also produced entirely through the tracked pmaports
packages.

## Repository layout

| Path | Purpose |
|---|---|
| `aports/` | Local postmarketOS package snapshots used during bring-up. |
| `docs/` | Public status, architecture, build, safety, and roadmap documentation. |
| `helpers/` | Small device-side diagnostic helpers. |
| `host/` | Host integration files such as udev and Gentoo configuration snippets. |
| `patches/` | Focused experimental kernel and boot patches. |
| `scripts/` | Reproducible build, inspection, test, and rescue tooling. |

The `src/`, `build/`, `images/`, `logs/`, `reports/`, `android-dumps/`,
`rootfs/`, `tools/`, and `pmbootstrap-work/` directories are local workspaces
and are not part of the Git history. Durable conclusions from experiments
belong in `docs/`; raw reports may contain device identifiers or proprietary
runtime data and must remain local.

## Documentation

- [Documentation index](docs/README.md)
- [Support status](docs/status.md)
- [Mainline bring-up fixes](docs/mainline-bringup.md)
- [Direct mainline boot](docs/direct-boot.md)
- [Boot architecture](docs/boot-flow.md)
- [Host setup](docs/host-setup.md)
- [Device safety](docs/device-safety.md)
- [Artifacts and reproducibility](docs/artifacts.md)
- [Source trees](docs/sources.md)
- [Roadmap](docs/roadmap.md)
- [Hardware enablement roadmap](docs/hardware-roadmap.md)
- [pmaports upstreaming plan](docs/pmaports-upstreaming.md)

## Contributing

Hardware reports, DT reviews, pmaports packaging help, and focused fixes are
welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
Reports should identify the exact model, kernel commit, DTB hash, boot method,
and observed result.

## License

The original tooling and documentation in this repository are licensed under
the GNU General Public License version 2. Third-party source snapshots and
derived files retain their respective upstream licenses. See [LICENSE](LICENSE).
