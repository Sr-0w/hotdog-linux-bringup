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

A debug kernel retaining the K1 Android entry layout and changing
`CONFIG_QCOM_WDT=m` to `CONFIG_QCOM_WDT=y` has also been built. Its Image
SHA256 is
`c1d19855e75dd1cfa7ab8e6dd21c0751b6c6f79b5bc588b6c4f5fa7d8d42941e`.
The only other config change is `CONFIG_WATCHDOG_SYSFS=y`; this is the next
kexec candidate. The change is tracked in
[mainline-direct-debug.fragment](../configs/mainline-direct-debug.fragment),
and [test-mainline617-qcom-wdt.sh](../scripts/test-mainline617-qcom-wdt.sh)
hash-checks the complete test tuple.

The same watchdog payload is prepared for direct header-v2 entry. Its raw
image SHA256 is
`c5b31bc45096705a16255efe059306368de97570cf2e385c6187227e346e4580`;
its AVB copy SHA256 is
`74ab6d70f54257399d6b3afe59eaba337a67fc2254355341e2cba52fd769627d`.
It must not be tested directly until the `c1d19855...` Image has reached SSH
through kexec and successfully rebooted to fastboot.

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
  --outdir "$PWD/images/pmos-experiments/direct-d1"
```

The builder re-extracts the result and byte-compares all three payloads. It
produces a raw image for a temporary test and a partition-sized `boot.img`
with an AVB `NONE` footer for structural validation. It also verifies that
footer with `avbtool verify_image`. It never communicates with the phone.

The default `100663296`-byte partition size is the value observed on the
tested HD1913. It is not permission to flash another device: verify that
device's partition geometry and recovery path independently.

## DTB-pack control

Some Qualcomm boot flows use a bare concatenation of FDT blobs and select an
entry from board identifiers. The builder supports that exact format, not an
Android `dt_table` container. It can replace one entry while preserving every
other FDT:

```bash
./scripts/build-mainline-direct-bootimg.sh \
  --kernel /path/to/Image \
  --dtb /path/to/sm8150-oneplus-hotdog.dtb \
  --ramdisk /path/to/initramfs.cpio \
  --cmdline-file /path/to/cmdline.txt \
  --source-dtb-pack /path/to/stock-hotdog.dtbpack \
  --dtb-entry 12 \
  --outdir "$PWD/images/pmos-experiments/direct-d1-pack"
```

The single-DTB form remains the primary D1 experiment because it changes the
fewest payload variables relative to kexec. The pack form is a control for
bootloader DTB selection.

## Follow-up matrix

| ID | Change from the validated baseline | Question answered |
|---|---|---|
| K0 | Boot the downstream bridge directly | Is the bootloader and recovery baseline intact? |
| K1 | Load the pinned mainline payload by kexec | Does the payload itself still work? |
| D1 | Put the exact K1 payload in header v2 | Which direct-handoff variables remain after payload parity? |
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

Temporary `fastboot boot` is preferred while direct entry is unproven. The
persistent downstream bridge remains the recovery image.

The validated Linux 6.17 config currently builds the Qualcomm APSS watchdog as
a module, while the root filesystem still contains downstream 4.14 modules.
That leaves mainline without its hardware restart handler after kexec. The
next debug kernel builds `CONFIG_QCOM_WDT=y`; this must be validated before
automating repeated direct-boot cycles without physical intervention.

## Completion criteria

The direct-boot milestone is complete when a pmaports-generated boot image:

1. starts Linux mainline directly from the bootloader;
2. mounts the installed postmarketOS root filesystem read-write;
3. exposes USB NCM, USB ACM, and SSH;
4. can reboot to bootloader and recovery without a physical reset;
5. reproduces from tracked pmaports packages without local binary payloads.
