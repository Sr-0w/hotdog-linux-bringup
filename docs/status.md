# Hardware support status

Last updated: 2026-08-05

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
| Mainline base | Hardware-validated ClearStaff Linux 6.16; shared pmaports target is SM8150 6.17 or newer |
| Bridge base | Lineage/OpenELA-derived Linux 4.14.357 |

Other `hotdog` variants may differ in modem, panel, firmware, and bootloader
behavior. Do not assume that an HD1913 result applies unchanged to every model.
The model mismatch above is reported explicitly because the vendor/recovery
identity is HD1911 even though the physical handset is labelled HD1913.

## Mainline support matrix

| Subsystem | State | Evidence or limitation |
|---|---|---|
| Kernel entry | Working directly and through kexec | The 4.14 bridge loads Linux 6.17, and the OnePlus bootloader directly starts the mainline-oriented ClearStaff 6.16 image through PID 1. |
| Mainline 6.16 pmaports image | Exact direct hardware boot working | Revision `r17` preserves the accepted hardware stack and exposes the stock 1440x3120 60 Hz and 90 Hz modes. Two strict builds produced the same kernel and DTB payloads. The hardware-tested AVB image `d93ec3b84cc2cb726cbfbdd932d1d40a5b2e2e3574a0a7c4615c9a4c125d43f0` returned SSH as `#18-oneplus-hotdog-mainline616`; scripted KScreen changes and manual Plasma Settings selection both work. |
| K1 kernel package | Current r5 build evidence, package hardware test pending | One `6.17.0-r5` strict pmbootstrap build produced a `27,172,103`-byte APK, SHA256 `f3083fd4c6af13be364eb0317873ee3a6f3690c5acb3a9e111c65b26b1746dd6`. Its `28,901,384`-byte `vmlinuz` is `417475432ab2db0a84a4a13d3b5c3dfd6b2c3b60236b58467fca4aafb110b118`; the transformed DTB remains `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440`. The embedded config was verified with RAID6 enabled, its benchmark disabled, and the Qualcomm watchdog built in. The complete r5 package payload has not yet been hardware-tested or double-built. |
| Device package metadata | Complete image hardware-validated | The version-2 metadata and `kernel-cmdline.conf` generated the pmaports image used on hardware. Its command line removes `quiet`/Plymouth, keeps `iommu.passthrough=0`, selects `TER16x32`, and boots successfully. Native 1440x3120 KMS scanout and dynamic selection between stock 60 Hz and 90 Hz are hardware-validated. |
| Persistent direct boot | Exact pmaports rootfs and networking working | The package-generated image boots from persistent `boot_b`, enumerates UFS, mounts the matching nested `pmOS_root` on `/dev/loop0p2`, completes `switch_root`, and starts OpenRC, USB networking, and SSH in 18 seconds. The current laboratory deployment stores the nested GPT in `userdata`; the final installation target remains open. |
| Device tree | Bring-up quality | Boots with temporary SMMU and ICE workarounds. Full-DDR analysis found three gaps between mainline and the stock HD1913 reservation union. `r21` fixed XBL/AOP; `r22` also excludes the remaining `removed_regions` and CDSP intervals. |
| UFS | Direct boot working; complete RAM-map A/B ready | Raw 1 GiB I/O and 120 seconds of direct random I/O pass. The buffered OSTree object still entered Qualcomm `900e` on `r21`, but a second complete DDR dump again found no Linux panic or UFS/ext4 failure. The active staging inode had moved from the fixed XBL/AOP gap into an omitted stock CDSP interval. The verified `r22` image closes every remaining stock reservation difference before repeating the import. |
| postmarketOS root | Working directly | The standard pmaports initramfs selects UUID `c0334266-a480-4c64-9faf-dd0c57a1e404`, expands it to the available space, mounts `/dev/loop0p2` read-write, and completes `switch_root`. |
| postmarketOS boot | Working directly | The matching `pmOS_boot` UUID is mounted read-write from `/dev/loop0p1`. |
| OpenRC userspace | Working directly | The exact pmaports rootfs starts OpenRC, NetworkManager, `sshd`, `rmtfs`, `pd-mapper`, and `tqftpserv`; host SSH is stable. |
| Plasma Mobile | Working on the direct-mainline system | The live root runs Plasma Mobile 6.7.3 through `tinydm`, with a usable full-screen shell, accelerated KWin, touch input, and USB SSH. Device package `3-r5` selects the standard mobile application set and `polkit-elogind`, then disables PowerDevil automatic suspend in all three profiles until resume is reliable. Two strict builds produced identical normalized metadata and installed configuration. A fresh-image hardware test remains pending. |
| USB NCM | Working directly | The pmaports image uses Apps SMMU stream `0x140` with a translated domain and unmodified generic DWC3/IOMMU source. It exposes the device at `172.16.42.1`; host ping and SSH are stable. |
| USB ACM | Enumerating directly | V43 exposes CDC ACM and creates `ttyGS0`. An interactive serial-session check remains pending. |
| Early console | Working through native fbcon | V42 switches `tty0` to a 90x97 color framebuffer console with the built-in Terminus 16x32 font and displays kernel plus postmarketOS output. |
| DRM/panel | Dynamic 60/90 Hz working | Native SM8150 DPU, DSI, TE, DSC, and the OnePlus Samsung panel produce correct 1440x3120 KMS scanout. Revision `r17` exposes both stock modes and sends the matching panel command during atomic changes. KScreen and Plasma Settings selection work. Lock/unlock recovered one purple scanout while USB SSH stayed alive; repeated blank/unblank and complete suspend/resume remain open. |
| Framebuffer | Working for direct-boot diagnostics | Mainline registers `fb0: msm`; both kernel fbcon and PID 1 framebuffer writes are visible. V31 adds a non-scrolling five-band geometry test and a `tty0` BusyBox shell. Repeated dense console output is now isolated from the correct KMS userspace path. |
| GPU | Working for rendering and accelerated scanout | The `r5` DT enables the Adreno 640 and GMU with the handset ZAP firmware path. Turnip Mesa 26.1.6 completes headless Vulkan workloads, while `kmscube` renders at approximately 60 FPS on the physical panel and Weston plus Plasma Mobile use Freedreno `FD640`. No post-test GPU/GMU/IOMMU fault or recovery was found. Suspend/resume remains untested. |
| RAM | Direct map working; complete stock reservation fix ready | Direct boot receives the bootloader's multi-gigabyte memory map. Under pressure, `r20` occupied the omitted XBL/AOP interval and `r21` occupied the next omitted CDSP interval. The verified `r22` A/B image and two byte-identical strict package builds make the mainline reserved-memory union cover every enabled stock HD1913 reservation. Hardware pressure validation remains pending. The historical kexec payload deliberately uses the low-bank window. |
| Apps SMMU | DWC3 validated; UFS translated-domain boot validated | V43 attaches DWC3 to stream ID `0x140` and uses a translated domain successfully with generic IOMMU and DWC3 source. Revisions `r18` and `r19` both boot UFS on stream `0x300` with ICE disabled; their DMA64 and DMA32 paths fail at the same buffered-import boundary, ruling out the aperture as the sole cause. Other clients and the complete SoC description remain unvalidated. |
| UFS ICE | Not working | ICE probe fails; UFS currently runs without the ICE dependency. |
| Kernel modules | Packaged and running | The 6.16 module tree is installed under `/usr/lib/modules/6.16.0-sm8150` and loads after `switch_root`. The exact `r6` boot loads the ABI-matched `s6sy761.ko` and binds the physical controller. MSM DRM and Adreno are built in. |
| Reboot | Historical module result; r5 built-in path untested | Under the historical module configuration, the exact 6.17 `qcom-wdt.ko` created `/dev/watchdog*` and produced a physical reboot. The r5 package has no watchdog module member because `CONFIG_QCOM_WDT=y`; built-in watchdog behavior is not hardware-validated. |
| Reboot mode | Bootloader mode hardware-validated through kexec | A mainline 6.17 kexec boot probed PM8150 PON with `mode-bootloader = <2>` and `RESTART2(bootloader)` returned directly to fastboot. Recovery-mode selection and early direct-boot integration remain unvalidated. |
| Touch and keys | Touchscreen working in graphical userspace; volume keys registered | The `r6` DTB exposes `pm8941_pwrkey` as `event0`, PM8150 PON `resin` / `KEY_VOLUMEDOWN` as `event1`, PM8150 GPIO 6 / `KEY_VOLUMEUP` as `event2`, and the S6SY761 as `event3`. Taps, drags, pressure, continuous X/Y coordinates, and multiple contact slots were hardware-validated on `r4`; Weston and Plasma Mobile confirm correct orientation and responsive touch. Physical volume-key press/release and suspend/resume remain open. |
| Firmware packages | Packaging complete, GPU and radio runtime validated | `firmware-oneplus-hotdog` `20241212-r0` produces eight APKs and 16 payloads under `/usr/lib/firmware`. The A630 SQE, A640 GMU, handset ZAP, MPSS, WCN3990 Wi-Fi, and revision-21 Bluetooth payloads are now runtime-validated. Other payloads and redistribution approval remain separate requirements. |
| Wi-Fi | Association and basic Internet reachability working | Revision `r13` boots MPSS, binds `ath10k_snoc` to WCN3990, exposes `wlan0`, and scans both bands. Revision `r15` associates through NetworkManager and reaches the local gateway plus an external IPv4 endpoint without packet loss while Bluetooth is active. Sustained throughput, factory MAC recovery, power management, and suspend remain open. |
| Bluetooth | Scanning and HID connections working; suspend open | Revision `r15` directly loads `crbtfw21.tlv` and `crnv21.bin`, exposes BlueZ, scans, and sustains real HID connections. One run entered `900e` at 275 seconds without a panic or system-suspend entry. Later clean windows completed for 600 seconds with Bluetooth blocked, 600 seconds with the controller active and connected, and 900 seconds after the controller was powered off. Repeated stability, audio profiles, power management, and suspend/resume remain open. |
| Audio | Not enabled | The exact pmaports boot reports no ALSA sound cards. Codec, routing, DSP, and userspace configuration remain open. |
| Modem | Remote processor running; telephony not validated | Revision `r12` proves the `0xfc201000` RMTFS assignment and boots MPSS to `running`; `rmtfs`, `tqftpserv`, QRTR, and PD mapper support are present. This enables WCN3990 services but does not yet provide a WWAN device, calls, SMS, data, GNSS, or SIM handling. |
| Cameras | Not validated | Camera pipeline support is not started. |
| Charging/battery | Basic limits corrected and hardware-validated | The `r7` audit exposed unsafe SMB2 conversions on SMB5 and that build is superseded. Revision `r8` directly verifies raw PM8150B settings for 4.40 V float voltage, 1.50 A fast-charge current, and 500 mA USB input. Its 61-sample, 180-second trace remained below the 4.42 V guard. Cable transitions, charge termination, low state of charge, thermal handling, suspend, and long-duration stability remain open. |
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

The exact current-pmaports package output now direct-boots on hardware. Its
kernel, source-built DTB, standard initramfs, split installation, and
deterministic AVB envelope were written with complete readback verification;
fresh SSH proved the new kernel and filesystem UUIDs. Hardware enablement can
therefore proceed over the package-built system:
the S6SY761 touchscreen, Adreno 640 render path, native dynamic 60/90 Hz scanout, Plasma
Mobile session, MPSS startup, WCN3990 association, and Bluetooth HID
connections are complete at basic runtime level, and both volume-key devices
now register. The remaining queue is stable Wi-Fi and Bluetooth addressing,
radio power management, extended charging policy, physical key validation,
display blank/unblank reliability, telephony, audio, sensors, cameras, and suspend. Temporary DMA and
bootloader-overlay workarounds, the laboratory `userdata` deployment, and the
device-specific kernel package must be replaced with upstreamable integration
before submission.

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
35. Keep D37 as the historical upper bound: its checkpoint after level 5
   (`fs`) was not reached.
36. Keep D38 and reproduced D39 as proof selecting `subsys` entries 1-69.
37. Keep rebased D40 as the valid upper bound: its checkpoint after entry 66
   was not reached under the same R6/B workflow.
38. Keep D41 as the valid lower bound: its checkpoint after entry 33 reset the
   phone until the bootloader selected R6 on slot A. The unresolved interval is
   entries 34-66.
39. Keep D45 as proof that the pre-MMU APSS watchdog is functional. Its
   20-second timeout reset the handset, after which ABL displayed the red
   failure screen.
40. Do not use A/B retry exhaustion as unattended recovery on the tested ABL.
   Slot B remained selected at retry count zero despite successful slot A.
41. Keep the kexec PON control as hardware evidence that PM8150
   `mode-bootloader = <2>` plus `RESTART2(bootloader)` returns to fastboot.
42. Treat the superseded early-PON series only as negative recovery experiments;
   none exposed host-visible fastboot without a manual reset.
43. Invalidate the superseded one-try D40-D52 series as initcall evidence.
44. Generate the r5 package direct image from its exact kernel and installed
   DTB. Record kernel, DTB, raw-image, and AVB hashes without reusing the
   historical r0 identity.
45. After direct boot reaches userspace, integrate the validated PON property
   in the pmaports DTB and separately verify recovery-mode selection.
46. Keep D42 as the valid upper bound: its checkpoint after entry 49 was not
   reached, narrowing the unresolved interval to entries 34-49.
47. Keep D43 as the valid lower bound: its checkpoint after entry 41 reset the
   phone until the bootloader selected R6 on slot A. The unresolved interval is
   entries 42-49.
48. Starting with D44 after entry 42, test the remaining entries in ascending
   order while reset-loop candidates can fall back to R6/A unattended.
49. Keep D44 as proof that entry 42 returns; continue with D45 after entry 43.
50. Keep D45 as proof that entry 43 returns; continue with D46 after entry 44.
51. Keep D46 as proof that entry 44 returns; continue with D47 after entry 45.
52. Keep D47 as proof that entry 45 returns; continue with D48 after entry 46.
53. Keep D48 as proof that entry 46 returns; continue with D49 after entry 47.
54. Keep D49 as proof that entry 47 returns; continue with D50 after entry 48.
55. Keep D50 as proof that entry 48 returns. Together with D42, this isolates
   entry 49, `raid6_select_algo`.
56. Keep the supervised no-benchmark result as proof that entry 49 returns when
   `CONFIG_RAID6_PQ_BENCHMARK=n`. The candidate reset into R6/A; software
   `RESTART2(bootloader)` then let the watcher restore exact R6/B and stock
   `dtbo_b` without physical input.
57. Use the r5 package config for the next direct candidate, but continue to
   investigate why the early `jiffies`-based benchmark stalls before treating
   benchmark removal as the final timer fix.
58. Keep the post-`paging_init()` mapping result as proof that a surviving
    `early_memremap()` pointer was invalid after `early_ioremap_reset()`. The
    normal linear mapping makes the post-init markers reliable.
59. Keep the PID 1-only syscall result as proof of active direct-boot EL0
    userspace. It recorded entry and return from the first syscall, a second
    syscall, and at least 16 calls without exposing USB.
60. Enforce the observed HD1913 bootloader limit of 511 command-line
    characters. The previous `rdinit=` lived in ignored `extra_cmdline`, so its
    syscall trace described the original `/init`, not the static wrapper.
61. Keep the compact-cmdline result as proof that the static wrapper really
    runs. Its PID 1 cells showed successful `openat()`, failed framebuffer
    access, successful `execve("/init")`, and sustained initramfs activity.
62. Keep the first eleven-cell stage result as proof that `/init` returns from
    `mount_proc_sys_dev`, arms the rescue watchdog, parses the command line, and
    reaches the first `jump_init_2nd`. Cells 0-5 filled while 6-10 remained
    hollow. Because that call executes `/init_2nd.sh` without returning on
    success, the remaining stall is after the stage-two handoff.
63. Keep the stage-two result as proof that `/init_2nd.sh` enters, sources both
    function libraries, returns from the watchdog call, and enters
    `setup_udev`. Cells 0-9 filled while cell 10 remained hollow, so that
    function did not return during the observation window.
64. Test the hash-pinned bounded-udev candidate. It keeps the proven kernel,
    DTB, and command line, then reuses cells 6-10 for `setup_udev` entry,
    returns from `udevd`, `udevadm trigger`, and `udevadm settle`, and return
    from `setup_usb_network`. A udev command still blocked after 15 seconds
    leaves its cell hollow while stage two continues. Its PID 1 rescue path
    also arms the APSS watchdog for 32 seconds with a bootloader restart
    reason, kicks it once per second until the 300-second logical deadline,
    and then stops feeding it. A full userspace wedge should therefore return
    to host-visible Fastboot without exhausting slot retries. Both the bounded
    progression and the userspace APSS integration remain pending hardware
    validation.
65. Keep the first bounded-udev launch as evidence for an independent early
    watchdog race. Two Sahara captures after separate boots both reported
    valid stage 400/detail 986: every initcall had returned, but the 30-second
    APSS watchdog bit before its following disable completed. A 120-second
    attempt wrapped the hardware's 20-bit timeout field to about 24 seconds.
    It still reached stage 400/detail 986 before entering `900e`, proving the
    kernel-side disable completed and exposing a second overflow: PID 1's old
    330-second request wrapped to about 10 seconds. The superseding image uses
    the maximum non-wrapping 32-second kernel deadline, disables it before
    stage 400, and feeds a separate 32-second PID 1 watchdog until the logical
    rescue deadline.
66. Keep the deep bounded-udev result as proof that PID 1 enters the sourced
    second stage, returns from both function-library sources and the static
    rescue-supervisor call, then stops inside `setup_udev`. Cells 0-8 filled
    while 9-10 remained hollow. The static rescue supervisor did not expose
    Fastboot during the 390-second host observation. The next candidate keeps
    the exact kernel, DTB, and command line but replaces ash background launches
    with a static `fork()`/`execvp()` helper and a monotonic 15-second timeout.
67. Keep the first static fork/exec hardware run as a second 9/11 result.
    Cells 0-8 filled while the aggregate `setup_udev` and USB cells remained
    hollow; no USB or automatic Fastboot return appeared. The follow-up keeps
    the same helper and remaps cells 6-10 to `setup_udev` entry, return from
    `udevd`, return from `udevadm trigger`, return from `udevadm settle`, and
    return from USB setup. This distinguishes the three child commands without
    changing the kernel, DTB, command line, or timeout policy.
68. Keep the per-command fork/exec result as proof that the first bounded
    `udevd -d --resolve-names=never` launch is the immediate stop. Cells 0-6
    filled while 7-10 remained hollow for the complete 390-second observation;
    no USB identity or automatic Fastboot return appeared.
69. Keep the `udev-skip` hardware result as proof that both
    `setup_usb_network` and `start_unudhcpd` return when udev is omitted. All
    11 cells filled for the complete 390-second observation, but no host USB
    identity, network interface, or automatic Fastboot return appeared.
70. Keep the `usb-probe` hardware result as proof that configfs and
    libcomposite are present during direct mainline stage two. Cells 0-7 filled
    while 8-10 remained hollow for the complete 390-second observation. No UDC,
    host USB identity, network interface, or automatic Fastboot return
    appeared. Test `dwc3-probe` next: cells 6-10 report diagnostic entry, the
    QCOM USB platform device, QCOM wrapper binding, HS PHY binding, and DWC3
    core binding.
71. Keep the `dwc3-probe` hardware result as proof that the sourced second
    stage reaches the DWC3 diagnostic, but the expected
    `/sys/bus/platform/devices/a6f8800.usb` entry is absent. Cells 0-6 filled
    while 7-10 remained hollow for the complete 390-second observation. No host
    USB identity or automatic Fastboot return appeared. Offline replay found
    that D7 changes `/soc@0` address and size cells from mainline `2/2` to
    downstream `1/1` without rewriting the four-cell child `reg` properties.
    Retest the unchanged boot image with the D3 no-op DTBO, which preserves the
    embedded mainline DTB byte-for-byte. Its DWC3 wrapper and HS-PHY subtrees
    match the DTB from the successful mainline kexec boot property-for-property.
72. Keep the repeated 7/11 D7 result as confirmation that the missing QCOM USB
    platform device is deterministic. The prepared D3 guarded candidate changes
    the overlay variable while retaining the same DWC3 trace. It also builds
    `CONFIG_QCOM_WDT=y`, adds PM8150 `mode-bootloader = <2>` and
    `mode-recovery = <1>`, and packages the static supervisor so a failed
    300-second run can request Fastboot and receive a two-second hardware
    watchdog fallback. Its AVB image SHA256 is
    `c5ade1ffaa458fe6943fda13c208c5e6df9ce3f5e2af8dec8cc7c599fc72ea30`;
    hardware validation is pending.
73. Keep the native-mainline UFS baseline as proof that removing vendor DTBO
    fragments 46, 59, and 60 preserves the mainline `qcom,sm8150-qmp-ufs-phy`
    and `qcom,ufshc` nodes. Both drivers bind, but device initialization stops
    at the first NOP and no UFS block device appears.
74. Keep native-UFS D10 as a controlled negative calibration result. Seven
    downstream PCS Gear 3 values compile and execute without regressing the
    diagnostic path, but `ufshcd_verify_dev_init()` still reports
    `NOP OUT failed -11`.
75. Treat all live UFS register access from the R6 rescue environment as
    unsafe. Raw MMIO stopped while the clock domain was gated. The replacement
    experiment then blocked inside `ufshcd_hold()` while leaving hibern8,
    triggered two vendor recovery `BUG` paths, and wedged module loading. The
    checked-in helper now fails closed before device lookup.
76. Keep native-UFS D11 as proof that the first HS-G3 bootstrap guard did not
    match the runtime tree. Its ramoops log contains no `HOTDOG_UFS_*` marker
    and still reports `NOP OUT failed -11`; the selected DTBO replaced the root
    identity with `qcom,sm8150-mtp` while retaining OnePlus
    `dtsi_no = 0x4d59`.
77. Keep native-UFS D12 as proof that the corrected runtime guard executes. It
    identified controller revision `4.1.0`, reduced the initial host maximum
    from Gear 4 to Gear 3, and started the PHY in HS-G3 Rate B. The first NOP
    still failed with `-11`, so the bootstrap limit alone is insufficient.
78. Keep native-UFS D13 as a controlled negative lane-calibration result. Its
    downstream revision-2 Gear 3 TX/RX overlay executed with the D12 HS-G3
    guard, but the first NOP still failed with `-11` at 0.928083 seconds. The
    complete 57,303-byte console and 4 MiB ramoops capture were recovered.
79. Keep native-UFS D14 as a controlled negative reset-order result. Its new
    path executed after the final QCOM host reset, but the first NOP still
    failed with `-11` at 0.939149 seconds. Its `reset=1` trace is not a physical
    readback: GPIO 175 is the dedicated SM8150 `UFS_RESET` pad and has no input
    bit in pinctrl, so the generic GPIO read API cannot sample it.
80. Keep native-UFS D15 as a controlled negative PCS-reset result. The trace
    proves that reset was asserted throughout calibration, cleared before the
    host reset was released, and remained clear afterwards. The first NOP still
    failed with `-11` at 0.939979 seconds; the complete 57,814-byte console and
    4 MiB diagnostic capture were recovered automatically.
81. Use passive R6 evidence for the downstream comparison. Its normal boot log
    records Gear 4, two lanes, Fast Rate B, Samsung device identity, and all
    LUNs. The failed hold operation's timeout handler additionally captured
    host registers, UFSHCI 3.0, and 37.5 MHz gated clock rates. Do not repeat
    the live probe; details and artifact hashes are in
    [the 2026-08-01 incident record](evidence/2026-08-01-r6-ufs-live-probe.md).
82. Keep the ClearStaff hotdog branch as an external DTS reference. At commit
    `403b56c33e2c` it enables the same UFS rails but omits the GPIO175
    `reset-gpios` property. D16 reuses the exact D13 kernel, initramfs, and
    filtered DTBO while removing only that embedded DTB property. The hardware
    test variant also omits `hotdog_rescue_watchdog_sec=120`, an operational
    change that leaves a stalled kernel untouched rather than scheduling a
    reboot. Its AVB SHA256 is
    `971ac2a5cf2dfb0ef55911eb20a05e5c98314e8ddc3b4bde4718b3aa664b70b7`,
    reproduced byte-for-byte twice.
83. Keep D16 as a passive negative boot result. The candidate was launched from
    verified R6 boot `3b9b4950-2808-46a6-81c9-9feaf723f81a` at 01:59:34 on
    2026-08-02. It exposed no Fastboot, USB gadget, or postmarketOS SSH during
    the initial 180-second observation and remained unavailable until manual
    recovery at 10:48. The guarded restore wrote the pinned stock DTBO and R6
    image, left the target in Fastboot, and the subsequent R6 boot exposed an
    empty `/sys/fs/pstore`. Therefore D16 does not establish whether its first
    UFS NOP answered; it only rules out property removal as sufficient for a
    usable direct boot. The full ClearStaff DTS differs globally from the
    current OnePlus-common plus 57-fragment effective tree, so test that exact
    external baseline before another local UFS register change.
84. Keep V30 as the first native-mainline display-console result. Its pinned
    image SHA256 is
    `eb3934f588e77baba78fa524ec370f53d4308d18097009d07571609af56e97a2`.
    On hardware, MSM DRM initialized, registered `fb0`, switched the console to
    180x195 characters, displayed readable kernel output, and continued into
    the postmarketOS initramfs. UFS still failed its first NOP with `-EAGAIN`,
    so no root block device or USB userspace appeared.
85. Test V31 before changing DPU, DSI, DSC, or panel parameters again. It keeps
    the V30 kernel, DTB, command line, and D7 overlay byte-identical and changes
    only the initramfs entry. Five large, unique, non-scrolling bands at known
    rows distinguish a scanout geometry fault from fbcon scroll corruption;
    an interactive BusyBox shell remains on `tty0`, and no automatic reboot or
    watchdog is armed. Its AVB image SHA256 is
    `cacc4751e1b2f3ed8085c0db0d1ff443d75ecfb57b7c6295d8187f4048b70834`.
86. Keep V41 as the first complete direct-mainline transport result. Its
    translated DWC3 Apps SMMU domain exposes stable NCM and ACM, and read-only
    SSH validation confirms Linux `6.16.0-sm8150+`, the postmarketOS rootfs,
    OpenRC, and `usb0` at `172.16.42.1`. Its AVB image SHA256 is
    `f7d2f9f51a3c7818df2148c1bf25c72cf7ee1545ac38c9c3847793820bf9b604`.
87. Keep V42 as the clean direct-mainline baseline. It retains V41's DTB,
    initramfs, translated-IOMMU setup, and direct-entry window, removes only
    the high-frequency EP0 trace from the kernel, and selects the built-in
    Terminus 16x32 console font. It reached verified SSH in 19 seconds and
    reported a 90x97 fbcon. Its AVB image SHA256 is
    `baeeeffc6a96f2416038a6468260b609950e63b8bd8b1f4c08d5980d812fe824`.
88. Keep V43 as the minimal-source hardware baseline. It rebuilds from pinned
    ClearStaff commit `403b56c33e2c` plus the public patch series and refuses
    any delta under generic USB or IOMMU code. Its DTB, initramfs, command line,
    translated DWC3 domain, and font match V42. A guarded `boot_b` write and
    readback matched exactly; one normal reboot reached fresh SSH in about 15
    seconds with boot ID `9f90f5bc-a2c9-4105-8827-eae7dc5addcd`. Its AVB image
    SHA256 is `a77e789f4991483eddb1671d03895a504faf1e1a6b9e1a3e78daadab5b87c2fd`.
89. Keep the first strict `linux-oneplus-hotdog-mainline616` build as the
    source-package milestone. It generates the DTB, Image, and modules without
    the forensic K1 binary-DTB transforms and passes the encoded V43 contract.
90. Keep the r3 current-pmaports build as the package-to-image milestone. It
    creates the normal initramfs, header-v2 Android boot image, `pmOS_boot`, and
    `pmOS_root`; its 397-byte command line preserves the translated DWC3 domain,
    removes `quiet`/Plymouth, and stays below the measured ABL limit.
91. Keep the deterministic AVB result as the source-to-partition-image
    milestone. Two independent wrappers produced byte-identical 96 MiB images,
    SHA256 `df87c5442859caeaeba08bfe2abb4f7b723437124b9764d9bf8d63b8be7a4fca`,
    whose footer, descriptor, raw prefix, and extracted payloads verify.
92. Keep the exact pmaports hardware boot as the package-to-device milestone.
    A deterministic two-partition image, SHA256
    `7bd3ab46012a9f73a5d2468a8a8d058fa7e3e527e1b9ed90f9392c4274db107c`,
    was staged and read back exactly from `userdata`; the AVB image above was
    read back exactly from `boot_b`. One normal reboot reached SSH in 18 seconds
    with boot ID `03d2e4e7-46df-4589-a3ee-d61b06659e25`, package-built kernel
    `6.16.0-sm8150`, and the matching pmaports boot/root UUIDs.
93. Keep the `r4` touchscreen run as the first direct-pmaports peripheral
    milestone. The exact APK kernel and DTB booted from AVB image
    `b90b54b4864ad265de088edf4e776751aeed805ae2201d9cb239fd55b33668ff`;
    S6SY761 registered at I2C `0-0048`, delivered 729 observed IRQs, continuous
    coordinates and pressure, and multiple simultaneous contact slots.

Exact timestamps, identities, and restore hashes for the checkpoint search are
recorded in
[the 2026-07-15 RAID6 evidence](evidence/2026-07-15-raid6-direct-boot.md).
The later mapping, PID 1, and command-line results are recorded in
[the 2026-07-30 direct PID 1 evidence](evidence/2026-07-30-direct-pid1.md).
The native UFS calibration sequence is recorded in
[the 2026-07-31 direct native UFS evidence](evidence/2026-07-31-direct-native-ufs.md).
The native panel and framebuffer-console sequence is recorded in
[the 2026-08-03 native display evidence](evidence/2026-08-03-native-display.md).
