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

## R5 no-op DTBO baseline control

The known-good R5 `boot_b` was tested with the same D3 no-op `dtbo_b`. It also
returned to fastboot in approximately 3.84 seconds and decremented the slot
retry count once. Rollback restored and read back original `dtbo_b` and exact
R5 `boot_b`. Therefore the no-op overlay is not a valid baseline even for the
downstream kernel, and D3 through D4-entry cannot isolate a mainline-only
failure. The next overlay must retain the stock fragments that resolve against
both downstream and K1 base DTBs.

## D5 and D6 filtered overlay controls

D5 reproducibly filters stock entry 5 by removing fragments whose external
fixups do not resolve in K1, then validates the result against both downstream
and mainline base DTBs. It retains 56 of 125 fragments. On hardware, R5 reached
the USB telnet initramfs with kernel `4.14.357-openela-perf`, but the nested
filesystem mount failed and strict SSH acceptance was not reached.

D6 adds K1 symbol aliases for the vendor UFS controller, PHY, and regulator
names before running the same filter. It retains 58 fragments, including
fragments 59 and 60. On hardware, R5 exposed `/dev/sda` through `/dev/sdf`, the
complete `/dev/sde*` partition set, USB NCM, and the `ttyGS0` ACM shell. The
transition after `pmos_continue_boot` did not produce SSH. The original DTBO
and exact R5 boot image were restored after D5 and read back by SHA256. D6
requires the same restoration after a manual return to fastboot.

The next cycle must prearm
[`guard-pmos-acm-continue.py`](../../scripts/guard-pmos-acm-continue.py) before
leaving the ACM shell. This captures the delayed initramfs log and schedules a
verified `RESTART2(bootloader)` fallback without requiring physical input. It
also reruns the `super` loop hook after late UFS discovery and refuses to
continue unless both pinned postmarketOS filesystem UUIDs are visible.

A repeat D6 cycle reached the downstream framebuffer console and then entered
Qualcomm crashdump mode (`05c6:900e`) before ACM. A complete 8 GiB Sahara RAM
capture was collected read-only. Scanning the full 4 MiB ramoops reservation
recovered the downstream console: `msm_watchdog` barked at 103.22 seconds,
reported its last pet at 92.08 seconds, and then forced a watchdog bite. This
makes D6 a timing-sensitive negative control rather than a stable downstream
baseline. The scanner is implemented by
[`extract-ramoops-console.py`](../../scripts/extract-ramoops-console.py) and is
used automatically by the full Sahara capture helper.

D7 retains the missing `vdd-hba-supply` fixup. Its K1
bridge adds an always-on fixed-regulator provider for the downstream-only
`ufs_phy_gdsc` symbol. The filtered D7 fragments 59 and 60 are structurally
identical to the stock overlay fragments, and the result applies successfully
to both downstream and bridged K1 base DTBs.

The D7 hardware control booted unchanged R5 through to fresh SSH. The accepted
identity was boot ID `fe700727-e7c3-4605-9881-b65e3b4d6daf`, kernel
`4.14.357-openela-perf`, and slot B. A strict read-only partition check then
matched R5 `boot_b` SHA256
`23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50`
and D7 `dtbo_b` SHA256
`c7b22d3c2b8d9d09d95ee9ef8f3ead91dae2d7ec85e259c03b44bc3b2afa8978`.
This promotes D7 from an offline candidate to the validated downstream DTBO
control for the next direct-mainline pairing.

The first pinned pairing launcher was
[`test-mainline617-direct-d8-d7-dtbo.sh`](../../scripts/test-mainline617-direct-d8-d7-dtbo.sh).
It paired D7 with the original exact K1 direct image and returned to fastboot
after approximately 26 seconds. Offline replay then exposed a missing contract:
the D1/D8 embedded DTB lacks D7's vendor-symbol and fixed-regulator bridge, so
applying D7 to the actual embedded DTB fails with `FDT_ERR_NOTFOUND`.

The corrected D9 image keeps the D1 kernel, ramdisk, command line, and header
byte-identical while replacing only the embedded DTB with the exact bridged K1
base used to filter D7. D7 applies successfully to that embedded DTB offline.
The pinned launcher is
[`test-mainline617-direct-d9-d7-bridge.sh`](../../scripts/test-mainline617-direct-d9-d7-bridge.sh).

## R6 no-watchdog rollback baseline

R6 keeps the R5 kernel and embedded DTB while adding only the downstream
`watchdog_v2.enable=0` command-line parameter. With the original stock DTBO it
reached fresh postmarketOS SSH on boot ID
`329a582e-755f-49c8-a8fa-a96c8d759ce7`. Read-only hardware verification
matched the first 61,808,640 bytes of `boot_b` to SHA256
`e76c85a56cdbcc6ddd105844eb322cb854fb33b2b23077da12ff098adc8f2369`
and complete `dtbo_b` to SHA256
`95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672`.
The D9 launcher and both rescue watchers now restore this exact pair.

## D9 direct result and D10 entry probe

D9 was written with D7 after a strictly verified R6 source boot. It remained
outside every host-visible USB mode for the full 540-second observation window:
no mainline SSH, ACM, NCM, ADB, fastboot, or Qualcomm crashdump identity was
observed. A manual hard reset exposed fastboot, where the prearmed watchers
restored stock `dtbo_b` followed by R6 `boot_b`. The subsequent fresh R6 boot
read back both restore hashes exactly. Ramoops was empty, so D9 is classified
as a prolonged silent block rather than a verified panic or userspace boot.

D10 retained D9's DTB, ramdisk, command line, header, and D7 overlay. Its only
payload change was the disassembled kernel probe whose first `primary_entry`
instructions issue PSCI `SYSTEM_RESET`. D10 exhausted all seven slot-B retry
attempts and left the slot marked unbootable; D9 had consumed only one attempt.
The OnePlus boot-failure screen then appeared. This differential result proves
that the bootloader executed the direct mainline `primary_entry` code.

D11 moves the same reset checkpoint after `record_mmu_state()`,
`preserve_boot_args()`, early stack setup, and `__pi_create_init_idmap()`. Every
non-kernel image component remains byte-identical to D9 and D10. Its result
reproduced the seven-reset loop and OnePlus boot-failure screen. Direct entry
therefore completes initial idmap construction successfully.

D12 moved the checkpoint after cache maintenance, `init_kernel_el()`, and
`__cpu_setup()`, immediately before `__primary_switch`. It reproduced the
seven-reset loop and exhausted the slot-B attempts. The subsequent R6 boot
read back `boot_b` as `e76c85a56cdbcc6ddd105844eb322cb854fb33b2b23077da12ff098adc8f2369`
and stock `dtbo_b` as
`95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672`.
The direct path therefore completes the entire pre-MMU setup block.

D13 places the checkpoint at the first instructions of `__primary_switched`.
Its AVB image SHA256 is
`5c7ca0cb7c77653d74c4e2fbee7af3e88fc568312af5809474e57816ca35b645`.
The DTB, ramdisk, command line, and Android image contract are byte-identical
to D9 through D12. D13 exposed no host-visible USB identity during the short
observation window, but it continued resetting until all seven slot-B attempts
were exhausted and the triangle-red boot-failure screen appeared. After manual
fastboot exposure, the watcher restored R6 plus stock DTBO. The resulting R6
boot ID was `1f60cd16-09de-444f-9455-6b40db597fb3`, and both partition hashes
matched exactly. D13 therefore proves `__enable_mmu()`, early kernel mapping
and relocation, and the virtual branch into `__primary_switched`.

D15 moved the reset to the final assembly checkpoint before `start_kernel()`.
Its AVB image SHA256 is
`0ebd90d0c89b0e3f68fcda0f52c0dd7fb7da387fc8f580244347545051726d41`.
It exhausted all seven slot-B attempts and left the slot unbootable. Fastboot
was exposed manually, after which the script restored R6 plus stock DTBO. The
fresh R6 boot ID was `e9991d64-d61c-45a2-835f-36b06336b758`, and both
partition hashes matched exactly. D15 proves the complete MMU-on assembly setup
and moves the first unknown boundary into C startup.

D16 called the same PSCI reset immediately after `setup_arch()` returned. Its AVB
image SHA256 is
`c4eae792d904b486001802feec7363e416f838552a540d3728f898c1863daf70`.
It exhausted all seven slot-B attempts and reached the triangle-red screen.
Fastboot was exposed manually, then rollback produced R6 boot ID
`e531eea3-9dbe-4740-8f4e-68eb0860fa07` with exact boot and DTBO hashes. D16
proves early C startup plus architecture and device-tree setup.

D17 moved the reset immediately after `console_init()`. Its AVB image SHA256 is
`18706ac45471e88835fff678ec9d1b97d149a1a0a16da1f0818a0bff388a6e7a`.
It exhausted all seven slot-B attempts and reached the triangle-red screen.
Fastboot was exposed manually, then rollback produced R6 boot ID
`84bf1e3f-72b2-4a3b-b18c-76197576f55a` with exact partition hashes. D17 proves
the central memory, scheduler, interrupt, timer, timekeeping, and console block.

D18 moved the reset immediately before `rest_init()`. Its AVB image SHA256 is
`f6c33388e9d4bf5589bf07ab732fe17ce44de52faf73a4aa6aa320bca0eba770`.
It exhausted all seven slot-B attempts and reached the triangle-red screen.
Fastboot was exposed manually, then rollback produced R6 boot ID
`48282387-b25a-4c91-9276-e73751a0d958` with exact partition hashes. D18 proves
the complete `start_kernel()` initialization sequence.

D19 moves the reset into PID 1, immediately after `kernel_init_freeable()`.
Its AVB image SHA256 is
`d61de0104cfe226c76c5349e0af99f6cf32dff1344d575a3d92701ef44ee329d`.
It did not reset and remained on the OnePlus `Powered by Android` logo for the
full 120-second observation window. No USB recovery path appeared. This places
the first unresolved interval between entry to `rest_init()` and return from
`kernel_init_freeable()`. Fastboot was exposed manually after one attempt, with
slot-B retry count `6` and `unbootable=no`. Rollback produced R6 boot ID
`0ed8b787-2f44-4309-84fa-b18a35e75a0a` with exact partition hashes.

D20 requests the reset after PID 1 observes `kthreadd` completion and before
`kernel_init_freeable()`. Its AVB image SHA256 is
`4d64de88f338f9f985dec1270d696a69dd7f5fb00b09741e3b556776f80ee42b`.
It exhausted all seven slot-B attempts and reached the triangle-red screen.
Fastboot was exposed manually with retry count `0` and `unbootable=yes`. This
proves task creation, scheduler handoff, and the transition into PID 1.
Rollback produced R6 boot ID `d642b148-937d-4be9-893d-cf5d91c02aca` with
exact partition hashes.

D21 moves the reset after `sched_init_smp()` and before topology workqueue setup
and regular initcalls. Its AVB image SHA256 is
`4763ebfe3ba2e33b91d5055c2c80b17c9a69a5ff063ed04bd14a69dc8c2701f7`.
It did not reset and remained on the OnePlus logo for the full 120-second
observation window. No USB recovery path appeared. The unresolved interval is
therefore between the D20 `kthreadd` handoff and completion of
`sched_init_smp()`. Fastboot was exposed manually after one attempt, with
slot-B retry count `6` and `unbootable=no`. Rollback produced R6 boot ID
`6f6e113e-40d0-44d5-904c-55f071d03711` with exact partition hashes.

D22 requests the reset after pre-SMP initcalls and immediately before
`smp_init()`. Its AVB image SHA256 is
`cbc1cfb693e24003d9f94625fbea9a7a9468dc709b465006beefb149f738505f`.
It exhausted all seven slot-B attempts and reached the triangle-red screen.
Fastboot was exposed manually with retry count `0` and `unbootable=yes`. This
isolates the D21 hang to `smp_init()` or `sched_init_smp()`. Rollback produced
R6 boot ID `614591d8-da02-4bbf-9a4e-72f32eeec3d2` with exact partition hashes.

D23 requests the reset after `smp_init()` and before `sched_init_smp()`. Its AVB
image SHA256 is
`cc87668f3debee208ff6baefd15d7f3ec218cffc989e885e9d2be25d7440aa98`.
It remained on the OnePlus logo for the full 120-second observation window and
never exposed USB. The checkpoint was not reached, which isolates the direct
boot hang inside `smp_init()`. Fastboot was exposed manually and the rescue
watcher restored both partitions. R6 then booted with ID
`7ad3e90b-dffe-4c14-b098-11629ea596ba`; strict device-side readback matched R6
`boot_b` SHA256
`e76c85a56cdbcc6ddd105844eb322cb854fb33b2b23077da12ff098adc8f2369`
and stock `dtbo_b` SHA256
`95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672`.

D24 keeps the D23 kernel checkpoint but adds `maxcpus=1` to the command line.
Its AVB image SHA256 is
`5b851b1e04623eb60622c7181e8974653c24c82b0875d31ca352af78877957c1`.
It remained on the fixed OnePlus logo for the full 120-second observation
window and never exposed USB. Limiting CPU activation does not make
`smp_init()` return, so a simple secondary-core bring-up failure is not a
sufficient explanation. Fastboot was exposed manually. R6 then booted with ID
`644f5f1d-005e-4e01-99a6-3ac4953bc2f3`; strict device-side readback matched
the exact R6 `boot_b` and stock `dtbo_b` hashes recorded above.

D25 retains `maxcpus=1` and requests the reset immediately after
`bringup_nonboot_cpus()` returns, before CPU counts and `smp_cpus_done()`. Its
kernel Image SHA256 is
`947f42dd235206d9db2edcefc6d78bf9d35fcb72e9d3a545214da6db5e48eef5`
and its AVB image SHA256 is
`73069cc8d1d9e04f1afe9c6f644c6495cd5dd65a71b73f3a2f99c11e8675505b`.
It remained on the fixed OnePlus logo for 120 seconds and never exposed USB,
so the checkpoint was not reached. Fastboot was exposed manually. R6 then
booted with ID `da7eb6c6-a65f-4685-816e-ee2003fc112a`; strict device-side
readback again matched the exact R6 `boot_b` and stock `dtbo_b` hashes.

D26 retains `maxcpus=1` and moves the reset immediately before
`bringup_nonboot_cpus()`, after `idle_threads_init()` and
`cpuhp_threads_init()`. Its kernel Image SHA256 is
`626385545ca98cc3fc02557823263c20e2979ff89fad5e680801b1fb6ce9f6d5`
and its AVB image SHA256 is
`3e04e8dd8284bc372e2a55330b888dc691bef28b05a2fc2db94f465468e697af`.
It exhausted all seven slot-B attempts and reached the triangle-red screen.
Together with D25, this isolates the hang to `bringup_nonboot_cpus()` itself.
Fastboot was exposed manually. R6 then booted with ID
`fac24965-e2f1-4e00-9fa8-de5857de3959`; strict device-side readback again
matched the exact R6 `boot_b` and stock `dtbo_b` hashes.

D27 reuses D23's post-`smp_init()` checkpoint and changes only the command line
to `maxcpus=0`, which makes `bringup_nonboot_cpus()` return immediately. Its AVB
image SHA256 is
`38e6efb5bc0dd9899955819a72d612a40544aff6dd76281f5cd0d8367ba41ced`.

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
