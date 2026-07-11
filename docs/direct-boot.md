# Direct mainline boot

The immediate project milestone is to boot the validated mainline payload
directly from the OnePlus bootloader, without first running the downstream
4.14 kernel.

## Known baseline

The following payload reaches the installed postmarketOS root filesystem when
loaded by kexec from the downstream bridge:

| Component | SHA256 |
|---|---|
| Linux 6.17 Image | `48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83` |
| Final bring-up DTB | `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440` |
| Wrapped initramfs | `b7e939614b7cb34ecdd8639613d76b8adba39b069b6591e35c39bc4c57a37622` |

Within the validated kexec path, this confirms that the kernel, DTB,
initramfs, UFS path, nested postmarketOS partitions, USB gadget, and userspace
work together. It does not yet prove that the Android bootloader hands the
same payload to Linux correctly.

The kernel tree is based on commit
`379d8fe35c7ca685a650bd82fd023af0ea3f0de0`. The payload hashes are the
experiment identity; a package-only reproduction from pmaports remains a
completion criterion rather than a current claim.

The source and generation path is:

- kernel repository: `https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux.git`
  at the commit above, with
  [the Android entry-layout patch](../patches/experimental-android-kernel-entry-layout.patch)
  and [the FTS build fix](../patches/mainline-fts-strict-prototypes.patch);
- DTB: the same tree's `sm8150-oneplus-hotdog.dts`, transformed by
  [build-mainline-pmos-boot-dtb.sh](../scripts/build-mainline-pmos-boot-dtb.sh)
  using the temporary changes documented in
  [mainline-bringup.md](mainline-bringup.md);
- initramfs: the postmarketOS initramfs wrapped by
  [build-mainline-pmos-wrapper-initramfs.sh](../scripts/build-mainline-pmos-wrapper-initramfs.sh).

Earlier direct candidates used older DTBs, different initramfs archives, or a
command line missing the final SMMU, wrapper, and timing parameters. They do
not isolate the bootloader handoff from the already fixed userspace problems.

## Prepared candidates

A local two-run check reproduced the single-DTB D1 boot images byte-for-byte;
this checks deterministic packaging, not clean-clone package reproducibility.
The raw image SHA256 is
`8eee58ec96bcaaba5563e1aed9c3a00ac4c41ac495bc9ca728a45aa0bcd56ae0`;
the deterministic AVB copy SHA256 is
`f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994`.
These hashes describe prepared artifacts, not a successful hardware result.
The raw `8eee58ec...` image is a temporary packaging and `fastboot boot`
artifact only; it must not be flashed. The AVB image
`f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994`
is the image pinned by the next persistent `boot_b` test.

A debug kernel retaining the K1 Android entry layout and changing
`CONFIG_QCOM_WDT=m` to `CONFIG_QCOM_WDT=y` has also been built. Its Image
SHA256 is
`c1d19855e75dd1cfa7ab8e6dd21c0751b6c6f79b5bc588b6c4f5fa7d8d42941e`.
The only other config change is `CONFIG_WATCHDOG_SYSFS=y`; this was prepared
as a watchdog/restart-handler debug control, not as the pinned D1 persistent
test. The change is tracked in
[mainline-direct-debug.fragment](../configs/mainline-direct-debug.fragment),
and [test-mainline617-qcom-wdt.sh](../scripts/test-mainline617-qcom-wdt.sh)
hash-checks the complete test tuple.

The same watchdog payload is prepared for direct header-v2 entry. Its raw
image SHA256 is
`c5b31bc45096705a16255efe059306368de97570cf2e385c6187227e346e4580`;
its AVB copy SHA256 is
`74ab6d70f54257399d6b3afe59eaba337a67fc2254355341e2cba52fd769627d`.
It is not the pinned D1 persistent test.

An additional control uses the same watchdog config with the unmodified
upstream EFI-compatible ARM64 header. Its Image SHA256 is
`6cd4ba4e7b47fd843f21690647ffb6099a7ce4e8302017b01aebecd3826fb93f`.
It is reserved for a later entry-layout comparison, not the first reboot test.

## D1: exact payload, Android header v2

D1 keeps the boot-image contract used by the working downstream image:

- Android boot header version 2
- page size 4096
- base address `0x00000000`
- kernel offset `0x00008000`
- ramdisk offset `0x01000000`
- tags offset `0x00000100`
- DTB offset `0x01f00000`

Only the payload is replaced with the kexec-validated mainline Image, DTB,
initramfs, and command line. This is the most useful direct test because:

- success would show that this header-v2 packaging and payload can cross the
  direct bootloader handoff;
- failure, while the identical kexec payload still succeeds, narrows the
  investigation to direct-entry variables such as ABL behavior, memory
  placement, DTB selection, AVB handling, or temporary-boot behavior.

Build D1 offline with:

```bash
./scripts/build-mainline-direct-bootimg.sh \
  --kernel /path/to/Image \
  --dtb /path/to/sm8150-oneplus-hotdog.dtb \
  --ramdisk /path/to/initramfs.cpio \
  --cmdline-file /path/to/cmdline.txt \
  --outdir /path/to/local-output/direct-d1
```

The builder re-extracts the result and byte-compares all three payloads. It
produces a raw image for a temporary test and a partition-sized `boot.img`
with an AVB `NONE` footer for structural validation. It also verifies that
footer with `avbtool verify_image`. It never communicates with the phone.

The default `100663296`-byte partition size is the value observed on the
tested HD1913. It is not permission to flash another device: verify that
device's partition geometry and recovery path independently.

## Pinned persistent D1 launcher

[test-mainline617-direct-d1.sh](../scripts/test-mainline617-direct-d1.sh) is
the next persistent direct-boot launcher. It intentionally narrows the test to
one pinned D1 image and one pinned recovery bridge:

| Item | Pinned value |
|---|---|
| image under test | D1 AVB image, `f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994` |
| restore image | r5 no-paint bridge, `23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50` |
| source state | `4.14.357-openela-perf` bridge on slot B, with the configured phone serial in `/proc/cmdline` |
| rescue policy | companion watcher prearmed before flashing `boot_b`; the restore hash is checked at readiness and immediately before flashing |
| expected kernel | `6.17.0-sm8150` prefix |
| expected target identity | new boot ID plus `rdinit=/hotdog-mainline-wrapper`, slot B, and the configured phone serial in `/proc/cmdline` |
| boot observation window | 540 seconds by default; overrides below 480 seconds are rejected |
| post-restore action | restore `boot_b` and reboot system when the recovery path appears |

The launcher rejects arguments that would change the image, restore image,
source mode, expected kernel, restore mode, rescue watcher, or boot-wait
policy. The target serial comes only from `HOTDOG_TARGET_SERIAL` or
`ANDROID_SERIAL`; command-line serial overrides are rejected. Only polling and
fastboot/rescue timing options remain adjustable.

The starting bridge must be a healthy postmarketOS SSH boot from slot B on the
configured handset. The launcher verifies its kernel, slot and serial markers
before flashing, prearms the rescue watcher, writes the pinned AVB image to
`boot_b`, reboots, and then classifies the result.

A success requires a fresh postmarketOS SSH boot ID, a kernel release starting
with `6.17.0-sm8150`, and all pinned target command-line markers. ADB, ping and
telnet remain diagnostics and cannot report success. The initramfs rescue
watchdog is acknowledged only after the SSH identity checks pass. A restored
bridge is not success: if SSH returns on downstream 4.14, or if fastboot returns
and the no-paint bridge is restored, the run only proves recovery worked. A
timeout without a USB recovery path leaves the companion watcher running.

The D1 ramdisk contains two concatenated `newc` archives. The older archive
still carries the historical framebuffer probe bytes, but the final effective
`hotdog_fb_test.sh` is the later wait-only replacement. Both offline validators
resolve the last archive member with
[`extract-last-newc-member.py`](../scripts/extract-last-newc-member.py) and
reject any effective RGB fill implementation. The observed RGB frames came
from an earlier downstream 4.14 bridge, not from mainline.

## DTB-pack control

Some Qualcomm boot flows use a bare concatenation of FDT blobs and select an
entry from board identifiers. The builder supports that exact format, not an
Android `dt_table` container. It can replace one entry while preserving every
other FDT. It rejects malformed or non-progressing FDT sizes and records both
the source pack and replaced original entry in `SHA256SUMS` and the manifest:

```bash
./scripts/build-mainline-direct-bootimg.sh \
  --kernel /path/to/Image \
  --dtb /path/to/sm8150-oneplus-hotdog.dtb \
  --ramdisk /path/to/initramfs.cpio \
  --cmdline-file /path/to/cmdline.txt \
  --source-dtb-pack /path/to/stock-hotdog.dtbpack \
  --dtb-entry 12 \
  --outdir /path/to/local-output/direct-d1-pack
```

The single-DTB form remains the primary D1 experiment because it changes the
fewest payload variables relative to kexec. The pack form is a control for
bootloader DTB selection.

## Follow-up matrix

| ID | Change from the validated baseline | Question answered |
|---|---|---|
| K0 | Boot the downstream bridge directly | Is the bootloader and recovery baseline intact? |
| K1 | Load the pinned mainline payload by kexec | Does the payload itself still work? |
| D1 | Flash the pinned AVB header-v2 image to `boot_b` with `test-mainline617-direct-d1.sh` | Does the exact K1 payload survive the persistent bootloader handoff? |
| D1-pack | Replace DTB-pack entry 12 with the K1 DTB | Does the bootloader require Android DTB selection? |
| D2 | Append the K1 DTB to Image in header v0 | Is separate-DTB handoff the failure? |
| D3 | Compare minimal and full command lines | Are injected Android bootargs involved? |
| D4 | Test an alternate non-overlapping kernel placement | Is the bootloader entry address wrong? |

Do not start D2-D4 until D1 has a recorded result. Each candidate must change
one handoff variable and retain the known-good payload hashes.

## pmaports integration target

The D1 contract maps to `deviceinfo_header_version="2"`,
`deviceinfo_append_dtb="false"`, a 4096-byte page, and the base, kernel,
ramdisk, tags, and DTB offsets listed above. The final device package must use
`deviceinfo_flash_fastboot_partition_rootfs="super"` rather than the legacy
`deviceinfo_flash_fastboot_partition_system` spelling.

The downstream 4.14 bridge belongs only in the downstream/rescue package path.
The publishable testing package must consume the maintained SM8150 mainline
kernel package and generate its boot image through the normal pmaports flow.

## Recovery requirement

Temporary `fastboot boot` remains useful only as a packaging and loader
control. The raw D1 artifact is not the persistent test image and must not be
flashed. The persistent downstream no-paint bridge remains the recovery image
and the pinned launcher restores it whenever the recovery path appears.

The K1-compatible Qualcomm watchdog module has been validated after mainline
userspace, but `RESTART2(bootloader)` still falls back to normal boot without
the missing boot-mode mapping. The D1 persistent test therefore depends on the
prearmed rescue watcher and restore image rather than on mainline rebooting
itself cleanly into fastboot.

## Completion criteria

The direct-boot milestone is complete when a pmaports-generated boot image:

1. starts Linux mainline directly from the bootloader;
2. mounts the installed postmarketOS root filesystem read-write;
3. exposes USB NCM, USB ACM, and SSH;
4. can reboot to bootloader and recovery without a physical reset;
5. reproduces from tracked pmaports packages without local binary payloads.
