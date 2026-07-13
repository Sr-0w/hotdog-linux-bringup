# Hardware support status

Last updated: 2026-07-13

## Tested hardware

| Item | Value |
|---|---|
| Device | OnePlus 7T Pro |
| Tested model | HD1913 rear label; recovery reports HD1911 |
| Codename | `hotdog` |
| SoC | Qualcomm SM8150-AC / Snapdragon 855+ |
| Architecture | AArch64 |
| Bootloader | Unlocked A/B bootloader |
| Userspace | postmarketOS edge, OpenRC |
| Mainline base | postmarketOS Qualcomm SM8150 Linux 6.17 branch |
| Bridge base | Lineage/OpenELA-derived Linux 4.14.357 |

Other `hotdog` variants may differ in modem, panel, firmware, and bootloader
behavior. Do not assume that an HD1913 result applies unchanged to every model.
The model mismatch above is reported explicitly because the vendor/recovery
identity is HD1911 even though the physical handset is labelled HD1913.

## Mainline support matrix

| Subsystem | State | Evidence or limitation |
|---|---|---|
| Kernel entry | Working through kexec | The 4.14 bridge loads and executes Linux 6.17. |
| K1 kernel package | Current r4 build evidence, not hardware-tested | Two `6.17.0-r4` builds in the tested pmbootstrap environment produced byte-identical `27,172,035`-byte APKs, SHA256 `74d7cff718be9a06b8858360fe56c1ccd8d1fd7653151546b0480029694d803e`. Their `28,901,384`-byte `vmlinuz` is `7fba453fd960515b526e7f562b9c682078ad800f27e5861db431ad9d7d4532b5`; the installed transformed DTB is `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440`. This does not establish hardware behavior or reproducibility with another toolchain. |
| Device package metadata | Structural validation only | The version-2 device metadata uses `kernel-cmdline.conf` containing `clk_ignore_unused` and has passed `dint` structural validation. This does not validate hardware; `deviceinfo_drm` must remain absent from a submission until the runtime DRM path works. |
| Persistent direct boot | `subsys`/`fs` initcalls under diagnosis | D36 proves levels 0-3 return, while D37 does not reach the checkpoint after level 5. D38 distinguishes level 4 (`subsys`) from level 5 (`fs`). |
| Device tree | Bring-up quality | Boots with temporary memory, SMMU, and ICE workarounds. |
| UFS | Working | Samsung UFS controller probes and exposes all Android partitions. |
| postmarketOS root | Working | Nested `pmOS_root` mounts read-write as `/dev/loop1`. |
| postmarketOS boot | Working | Nested `pmOS_boot` mounts as `/dev/loop0`. |
| OpenRC userspace | Working | Core boot, NetworkManager, SSH, and local services start. |
| USB NCM | Working | The device is reachable at `172.16.42.1`. |
| USB ACM | Working | A serial shell is exposed on `ttyGS0`. |
| Early console | Partial | Kernel text is visible before the display path is lost. |
| DRM/panel | Not working | Mainline display clocks and the panel pipeline are not enabled. |
| Framebuffer | Not working | `simple-framebuffer` fails to reserve its memory with `-12`. |
| RAM | Partial | Approximately 448 MiB is available with the low-bank map. |
| Apps SMMU | Not working | Registration fails with `-EINVAL`; selected clients bypass it. |
| UFS ICE | Not working | ICE probe fails; UFS currently runs without the ICE dependency. |
| Kernel modules | Incomplete | The installed rootfs still contains downstream 4.14 modules. |
| Reboot | Historical module result; r4 untested | Under the historical module configuration, the exact 6.17 `qcom-wdt.ko` created `/dev/watchdog*` and produced a physical reboot. The r4 package has no watchdog module member because `CONFIG_QCOM_WDT=y`; built-in watchdog behavior is not hardware-validated. |
| Reboot mode | Staging patch only, not hardware-validated | The observed `cf63ae...` DTB and the r4 K1 package do not include PON reboot-mode properties. The separate SM8150 staging patch adds `mode-bootloader = <2>` and `mode-recovery = <1>` and has offline `fdtget` evidence only. This does not prove RESTART2 fastboot works. |
| Touch | Not enabled | Android identifies a Samsung `sec-s6sy761` controller. |
| Firmware packages | Packaging complete, runtime not validated | `firmware-oneplus-hotdog` `20241212-r0` produces eight APKs and 16 payloads, all under `/usr/lib/firmware`. This proves package layout, not peripheral operation or redistribution approval. |
| Wi-Fi/Bluetooth | Not validated | The usrmerged firmware packages exist; runtime loading, enumeration, and connectivity remain pending. |
| Audio | Not validated | Codec, routing, and userspace configuration remain open. |
| Modem | Not validated | QRTR/QMI and modem firmware integration remain open. |
| Cameras | Not validated | Camera pipeline support is not started. |
| Charging/battery | Not validated | Power-supply and charging behavior need dedicated testing. |
| USB host/dock | Not validated | Device-role USB is proven; host-role operation is not. |

## Downstream support

The downstream 4.14 kernel remains useful as a bridge and rescue environment.
It provides UFS, USB networking, SSH, USB ACM, simplefb/fbcon, and a working
downstream-only MSM DRM path capable of showing a test pattern and text
console. That path is a diagnostic reference, not a publication target.

Downstream support is not the project endpoint. New functionality should be
implemented in pmaports and the mainline-oriented kernel path whenever
possible.

## Definition of the next milestone

The next milestone is a reproducible pmaports build that boots mainline without
the downstream kexec bridge, exposes the complete RAM map, and retains USB SSH.
Display support can then be developed without losing the remote debug channel.

## Current validation queue

1. Preserve R6 plus the stock DTBO as the recovery baseline. Fresh downstream
   SSH boot ID `329a582e-755f-49c8-a8fa-a96c8d759ce7`, slot-B identity,
   `watchdog_v2.enable=0`, R6 `boot_b` SHA256 `e76c85...`, and stock `dtbo_b`
   SHA256 `95a111...` were read back from hardware exactly.
2. Keep D1, D1-pack, and D2 classified as observed negative handoff results.
   All exact AVB writes returned to fastboot USB without an accepted mainline
   identity; the tested header and DTB placement variants did not change it.
3. Keep D3, D3-wdt, and D4-entry as negative controls. Raw host USB measured
   the same approximately 3.84-second return for all three; each rollback was
   read back exactly and left no pstore record.
4. Keep the downstream R5 + no-op DTBO result as a failed baseline control.
   It proves that removing all 125 stock fragments is not viable.
5. Keep D5 as the first structurally valid dual-base overlay result. It boots
   R5 into the initramfs but does not provide a complete downstream control.
6. Keep D6 as the UFS-symbol bridge result. It exposes every UFS LUN and USB
   ACM, but the rootfs transition after `pmos_continue_boot` remains unverified;
   a repeat cycle entered Qualcomm `900e` crashdump mode.
7. Use D7 as the validated DTBO control. Unchanged R5 reached fresh SSH with
   boot ID `fe700727-e7c3-4605-9881-b65e3b4d6daf`; exact readback matched R5
   `boot_b` SHA256 `23fa53...` and D7 `dtbo_b` SHA256 `c7b22d...`.
8. Keep D9 as a prolonged silent-block result: no USB identity for 540 seconds,
   exact rollback afterward, and no ramoops record.
9. Keep D10 as positive direct-entry evidence. The first `primary_entry`
   instructions exhausted all seven slot attempts through PSCI reset.
10. Keep D11 as proof that MMU-state detection, boot-argument preservation,
   early stack setup, and initial idmap creation complete in direct boot.
11. Keep D12 as proof that cache maintenance, `init_kernel_el()`, and
   `__cpu_setup` complete immediately before `__primary_switch`.
12. Keep D13 as proof that `__enable_mmu()`, `__pi_early_map_kernel()`, and the
   virtual branch reach the first `__primary_switched` instructions.
13. Keep D15 as proof that task/stack setup, vectors, FDT preservation,
   `kimage_voffset`, boot-mode state, and `finalise_el2` all complete.
14. Keep D16 as proof that early C, initial CPU/page state, `setup_arch()`, and
   device-tree processing complete in direct boot.
15. Keep D17 as proof that central memory, scheduler, RCU, IRQ, timers,
   timekeeping, interrupt enable, late slab, and console setup complete.
16. Keep D18 as proof that the complete `start_kernel()` initialization
   sequence reaches the boundary before `rest_init()`.
17. Keep D19 as the upper bound: its post-`kernel_init_freeable()` checkpoint
   was not reached during the 120-second hardware window.
18. Keep D20 as proof that task creation, scheduler handoff, and entry into
   PID 1 complete before the unresolved `kernel_init_freeable()` body.
19. Keep D21 as the upper bound: its post-`sched_init_smp()` checkpoint was not
   reached during the 120-second hardware window.
20. Keep D22 as proof that pre-SMP setup completes before `smp_init()`.
21. Keep D23 as the upper bound: its post-`smp_init()` checkpoint was not
   reached during the 120-second hardware window. Manual fastboot exposure
   allowed exact R6 plus stock-DTBO rollback.
22. Keep D24 as evidence that `maxcpus=1` does not make `smp_init()` return.
   It stayed on the fixed logo for 120 seconds without USB; manual fastboot
   exposure allowed exact R6 plus stock-DTBO rollback.
23. Keep D25 as evidence that the checkpoint after `bringup_nonboot_cpus()` is
   not reached with `maxcpus=1`. It stayed on the fixed logo for 120 seconds;
   manual fastboot exposure allowed exact R6 plus stock-DTBO rollback.
24. Keep D26 as proof that idle/hotplug thread setup completes before
   `bringup_nonboot_cpus()`. It exhausted all slot-B attempts and reached the
   triangle-red screen; manual fastboot exposure allowed exact rollback.
25. Keep D27 as evidence that `maxcpus=0` does not reach the post-`smp_init()`
   checkpoint. It stayed on the fixed logo for 120 seconds without USB; manual
   fastboot exposure allowed exact R6 plus stock-DTBO rollback.
26. Keep D28 as evidence that boot-image `maxcpus=0` does not reach the
   checkpoint immediately after `bringup_nonboot_cpus()`. It stayed on the
   fixed logo for 120 seconds; manual fastboot exposure allowed exact rollback.
27. Keep D29 as proof that forcing `setup_max_cpus = 0` in-kernel makes
   `bringup_nonboot_cpus()` return. It exhausted all slot-B attempts and reached
   the triangle-red screen; exact R6 plus stock-DTBO rollback was verified.
28. Keep D30 as proof that the forced single-CPU bypass carries direct boot
   through the complete `smp_init()` call. It reproduced the slot-B reset loop.
29. Keep D31 as evidence that removing the checkpoint does not yet produce a
   verified userspace. The display went black, briefly showed fastboot, then
   held the OnePlus logo; no USB or SSH appeared during 360 seconds.
30. Keep D32 as proof that `sched_init_smp()` returns with the forced bypass. It
   reproduced the slot-B reset loop.
31. Keep D33 as proof that workqueue topology, async, padata, and late
   page-allocation setup return. It reproduced the slot-B reset loop immediately
   before `do_basic_setup()`.
32. Keep D34 as the upper bound: its checkpoint after `do_basic_setup()` was not
   reached during the 120-second window and the display held the OnePlus logo.
33. Keep D35 as proof that `cpuset_init_smp()`, `driver_init()`,
   `init_irq_proc()`, and `do_ctors()` return before `do_initcalls()`.
34. Keep D36 as proof that initcall levels 0-3 (`pure` through `arch`) return.
35. Keep D37 as the upper bound: its checkpoint after level 5 (`fs`) was not
   reached, limiting the hang to levels 4-5.
36. Test D38 after initcall level 4 (`subsys`). A reset identifies level 5
   (`fs`); no reset identifies level 4 (`subsys`).
37. Defer the r4 package-generated direct image until a direct handoff baseline
   works. Record its kernel, installed DTB, raw-image, and AVB hashes without
   reusing the historical r0 identity.
38. After a direct mainline entry succeeds, test the hotdog-only PON reboot-mode
   properties and verify RESTART2 bootloader and recovery selection.
