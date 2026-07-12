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
historical experiment identity. The current r4 package builds offline with a
built-in Qualcomm watchdog and installs the transformed `cf63ae...` DTB. Two
builds are byte-identical in the tested pmbootstrap environment, but the r4
payload has not been tested on hardware and no cross-toolchain reproducibility
claim is made.

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

## Candidate identities

A local two-run check reproduced the single-DTB D1 boot images byte-for-byte;
this checks deterministic packaging, not clean-clone package reproducibility.
The raw image SHA256 is
`8eee58ec96bcaaba5563e1aed9c3a00ac4c41ac495bc9ca728a45aa0bcd56ae0`;
the deterministic AVB copy SHA256 is
`f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994`.
The AVB image was later tested persistently and returned to fastboot without an
accepted mainline identity; the hashes do not describe a successful mainline
boot.
The raw `8eee58ec...` image is a temporary packaging and `fastboot boot`
artifact only; it must not be flashed. The AVB image
`f8e83ae15cb016612433b8a2d800d828b025d56c76640a2ebb41a3061baf8994`
is the image used by the recorded persistent D1 test.

A debug kernel retaining the K1 Android entry layout and changing
`CONFIG_QCOM_WDT=m` to `CONFIG_QCOM_WDT=y` has also been built. Its Image
SHA256 is
`c1d19855e75dd1cfa7ab8e6dd21c0751b6c6f79b5bc588b6c4f5fa7d8d42941e`.
The only other config change is `CONFIG_WATCHDOG_SYSFS=y`; this is prepared as
the D1-wdt debug control after D2, not as a result of either completed cycle.
The change is tracked in
[mainline-direct-debug.fragment](../configs/mainline-direct-debug.fragment),
and [test-mainline617-qcom-wdt.sh](../scripts/test-mainline617-qcom-wdt.sh)
hash-checks the complete test tuple.

The same watchdog payload is prepared for direct header-v2 entry. Its raw
image SHA256 is
`c5b31bc45096705a16255efe059306368de97570cf2e385c6187227e346e4580`;
its AVB copy SHA256 is
`74ab6d70f54257399d6b3afe59eaba337a67fc2254355341e2cba52fd769627d`.
It has not been tested on hardware.

This standalone debug payload is distinct from the package path. The debug
payload also enables `CONFIG_WATCHDOG_SYSFS=y`; the current r4 package keeps
that option disabled and changes only `CONFIG_QCOM_WDT=m` to
`CONFIG_QCOM_WDT=y` relative to the historical K1 config.

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
initramfs, and command line. This was the first persistent direct test because:

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

## Persistent D1 launcher and result

[test-mainline617-direct-d1.sh](../scripts/test-mainline617-direct-d1.sh) is
the launcher used for the recorded persistent D1 cycle. It narrows the test to
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

On 2026-07-12, the D1 AVB image was written to `boot_b` and read back with the
exact pinned hash before reboot. Downstream USB disconnected at `13:27:38` and
fastboot `18d1:d00d` appeared at `13:27:41`. No mainline
`bcdDevice=0617`, ACM, NCM, or `900e` state was observed. The result is a
negative direct-handoff signal, not mainline success. R5 was restored, a fresh
downstream SSH boot was confirmed, and the later `boot_b` readback matched the
pinned R5 hash exactly.

The complete public record is
[the 2026-07-12 direct-boot evidence](evidence/2026-07-12-direct-boot.md).

The D1 ramdisk contains two concatenated `newc` archives. The older archive
still carries the historical framebuffer probe bytes, but the final effective
`hotdog_fb_test.sh` is the later wait-only replacement. Both offline validators
resolve the last archive member with
[`extract-last-newc-member.py`](../scripts/extract-last-newc-member.py) and
reject any effective RGB fill implementation. The observed RGB frames came
from an earlier downstream 4.14 bridge, not from mainline.

## Historical r0 package-built reproducibility control

The offline candidate
`images/pmos-experiments/2026-07-11-224500-mainline617-pmaports-k1-direct`
keeps the historical D1 single-DTB layout, final transformed DTB, wrapped
initramfs, and command line. It changes the kernel input to the `vmlinuz`
actually emitted by the `linux-oneplus-hotdog-mainline617-k1` APK:

| Item | SHA256 |
|---|---|
| package-built kernel | `e9e2249b4ea8a749ceef7fb481a214fb0ac049f17a0a78ba8699e41d1535af5b` |
| raw header-v2 image | `63badda8d95b291248c91a8864dfa23f5e1f14a9d6346b9a036d08fd0273a0cd` |
| AVB `NONE` image | `94df0da7f7067f6769aa86b0da091ccdd0252e17420bb464830119e71641a06e` |

This candidate is a package-reproducibility test only after a direct mainline
handoff baseline has been validated on hardware. It remains deferred because
D1 and D1-pack returned to fastboot without an accepted mainline identity.

The r3 package supersedes r0 as an intermediate package result. It builds
`qcom-wdt` into the kernel and replaces the installed hotdog DTB with
`cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440`.
Across two r3 builds, the DTB, modules, and `modules.builtin` are identical,
while the APK metadata varies and `vmlinuz` differs by 29 bytes from the GNU
build ID and three initramfs CPIO mtimes. r3 is therefore not byte-reproducible.

The current r4 fixes the archive epoch at `1761609785`. Two builds in the
tested pmbootstrap environment produced byte-identical `27,172,035`-byte APKs,
SHA256 `74d7cff718be9a06b8858360fe56c1ccd8d1fd7653151546b0480029694d803e`.
Their `28,901,384`-byte `boot/vmlinuz` has SHA256
`7fba453fd960515b526e7f562b9c682078ad800f27e5861db431ad9d7d4532b5`,
and their installed hotdog DTB has SHA256
`cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440`.
The exact payload inventory is recorded in
[the K1 package evidence](evidence/k1-kernel-package.md). This proves
same-environment package reproducibility only, not hardware behavior or
cross-toolchain reproducibility. A distinct r4 direct-boot candidate and its
raw-image and AVB hashes remain to be recorded; none of the r0 hashes above
identify r3 or r4.

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

The single-DTB form was the primary D1 experiment because it changes the fewest
payload variables relative to kexec. The pack form was the next control for
bootloader DTB selection.

[test-mainline617-direct-d1-pack.sh](../scripts/test-mainline617-direct-d1-pack.sh)
is the pinned D1-pack launcher. It is a single-variable fallback relative to the
historical D1 candidate: the final K1 DTB replaces entry 12 in the concatenated
Android DTB pack, while the historical kernel, ramdisk, command line, header,
and offsets remain unchanged. It pins raw image SHA256
`f72e8eab80d07fe265bfe5520228b3ff758d47980a2f0204f774b14d5314b1ac`
and AVB image SHA256
`2f3bf9b7cde3b2d48a3cf4d6fe2fb2f92e210e1a6b1249505fa15be10c26b754`.
It was run after the historical single-DTB D1 result. The exact AVB image was
written and read back before reboot. Downstream USB disconnected at `13:36:16`
and fastboot `18d1:d00d` appeared at `13:36:20`; no mainline
`bcdDevice=0617`, ACM, NCM, or `900e` state was observed. R5 was then restored
and re-attested by fresh SSH and an exact later `boot_b` readback. Replacing
DTB-pack entry 12 is therefore not sufficient for direct boot on the tested
handset.

## D2 header-v0 append-DTB control

[test-mainline617-direct-d2-header0.sh](../scripts/test-mainline617-direct-d2-header0.sh)
retains the exact K1 Image
`48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83`,
DTB `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440`,
and ramdisk
`b7e939614b7cb34ecdd8639613d76b8adba39b069b6591e35c39bc4c57a37622`.
Only the boot-image contract changes from header v2 with a separate DTB section
to header v0 with the DTB appended to the kernel payload.

| D2 artifact | SHA256 |
|---|---|
| AVB image | `2076c16598a63bfcfea416b47789eacf74086e33919c0715949cd42719f9b71e` |
| Raw image | `c7c07a0cbf1311395343135253a10b555381f97ff32509c77257fc7b3aee3614` |
| Appended payload | `9fa9e318cf9d1efea349028a4c1e80b8477fd4839d7a73d3efdc0a0e5811bd09` |

D2 was written and read back exactly on hardware, then returned to fastboot
without an accepted mainline identity. R5 was restored and verified afterward.
Changing from header v2 with a separate DTB to header v0 with an appended DTB
did not change the observed result class.

## D3 no-op DTBO control

[test-mainline617-direct-d3-dtbo-noop.sh](../scripts/test-mainline617-direct-d3-dtbo-noop.sh)
tests a bootloader-applied overlay mismatch while keeping the D1 `boot_b`
payload unchanged. Stock DTBO entry 5 applies to the downstream DTB but fails
against the K1 DTB with `FDT_ERR_NOTFOUND`. The candidate replaces only that
entry with a no-op overlay and keeps the original DTBO table layout and size.
The candidate can be reproduced from the exact tested stock dump and K1 DTB
with [build-d3-noop-dtbo.sh](../scripts/build-d3-noop-dtbo.sh); the builder
pins both input hashes and the expected final image hash.

The D3 launcher pins candidate and restore hashes for both `dtbo_b` and
`boot_b`, requires two version-3 rescue watcher contracts, and holds one
inherited phone lock across the R5 reboot-to-bootloader transition and all
candidate writes. Rollback order is original `dtbo_b`, R5 `boot_b`, slot B,
then reboot. On hardware, D3 returned to fastboot after about 32 seconds with
no accepted mainline identity. The later return relative to D1/D2 proves that
the no-op overlay changes the handoff, but it is not sufficient. Both restored
partitions were verified from a fresh R5 boot and pstore was empty.

## D1 watchdog control

[test-mainline617-direct-d1-wdt.sh](../scripts/test-mainline617-direct-d1-wdt.sh)
is prepared after D2. It retains the D1 header-v2 layout, ramdisk, transformed
DTB, command line, and rollback policy while changing only the kernel to
`c1d19855e75dd1cfa7ab8e6dd21c0751b6c6f79b5bc588b6c4f5fa7d8d42941e`
with `CONFIG_QCOM_WDT=y` and `CONFIG_WATCHDOG_SYSFS=y`. The raw image is
`c5b31bc45096705a16255efe059306368de97570cf2e385c6187227e346e4580`;
the AVB image is
`74ab6d70f54257399d6b3afe59eaba337a67fc2254355341e2cba52fd769627d`.

This control has passed offline validation but has not been booted. The
watchdog remains a secondary hypothesis rather than a proven cause because the
observed D1 and D1-pack returns to fastboot USB occurred within three to four
seconds.

## Follow-up matrix

| ID | State or change | Result or question |
|---|---|---|
| K0 | Observed: boot the R5 downstream bridge directly | Fresh 4.14 SSH, slot B, configured serial marker, and exact rollback readback confirm the tested recovery baseline. |
| K1 | Observed: load the pinned mainline payload by kexec | The exact K1 payload reaches postmarketOS userspace through the bridge. |
| D1 | Observed: exact K1 payload in persistent header v2 | Returned to fastboot in about three seconds without an accepted mainline USB identity. |
| D1-pack | Observed: replace DTB-pack entry 12 | Returned to fastboot in about four seconds; the pack replacement is not sufficient. |
| D2 | Observed: append the exact K1 DTB to Image in header v0 | Returned to fastboot; the alternate header and DTB placement are not sufficient. |
| D3 | Observed: replace incompatible stock DTBO entry 5 with a no-op | Returned to fastboot after about 32 seconds; later than D1/D2 but still no accepted mainline identity. |
| D3-wdt | Observed: keep D3 DTBO and substitute the built-in-watchdog kernel | Returned after the same about 32 seconds; built-in watchdog does not change the boundary. |
| D4-entry | Prepared: PSCI reset at the first `primary_entry` instructions | Does ABL actually enter the arm64 kernel? |
| D1-wdt | Superseded by D3-wdt | Testing the watchdog kernel with stock DTBO would reintroduce the known overlay mismatch. |
| D1-pkg | Deferred until a direct handoff works: use the hash-recorded r4 package kernel and installed DTB | Does the pmaports-built payload reproduce a successful direct baseline? |
| D4 | Test an alternate non-overlapping kernel placement | Is the bootloader entry address wrong? |

D1, D1-pack, D2, D3, and D3-wdt now have recorded negative results. D4-entry is next.
Keep the package-built control deferred until a direct handoff baseline
exists. Each candidate must change one handoff variable and retain the other
known-good payload hashes.

## pmaports integration target

The D1 header-v2 candidate maps to `deviceinfo_header_version="2"`, a 4096-byte
page, and the base, kernel, ramdisk, tags, and DTB offsets listed above. Its
persistent return to fastboot means those fields are not yet a validated
direct-boot contract. Kernel arguments are supplied by `kernel-cmdline.conf`,
currently containing
`clk_ignore_unused`, rather than the deprecated `deviceinfo_kernel_cmdline`
field. The final device package must use
`deviceinfo_flash_fastboot_partition_rootfs="super"` rather than the legacy
`deviceinfo_flash_fastboot_partition_system` spelling.

The migrated metadata passes `dint` as a structural check. That result does
not establish display support: `deviceinfo_drm` must remain absent until the
mainline DRM, DSI, panel, and userspace path is validated at runtime.

The downstream 4.14 bridge belongs only in the downstream/rescue package path.
The publishable testing package must consume the maintained SM8150 mainline
kernel package and generate its boot image through the normal pmaports flow.

## Recovery requirement

Temporary `fastboot boot` remains useful only as a packaging and loader
control. The raw D1 artifact is not the persistent test image and must not be
flashed. The persistent downstream no-paint bridge remains the recovery image
and the pinned launcher restores it whenever the recovery path appears.

The historical K1-compatible Qualcomm watchdog module was validated after
mainline userspace, but that result does not validate the r4 or D1-wdt built-in
driver.
`RESTART2(bootloader)` still falls back to normal boot with the observed
`cf63ae...` DTB, which lacks the PON boot-mode mapping. The D1 and D1-pack
cycles demonstrated that the prearmed watcher can restore R5 when fastboot
returns. D2 and later persistent controls continue to depend on this recovery
path rather than on mainline rebooting itself cleanly into fastboot.

## Completion criteria

The direct-boot milestone is complete when a pmaports-generated boot image:

1. starts Linux mainline directly from the bootloader;
2. mounts the installed postmarketOS root filesystem read-write;
3. exposes USB NCM, USB ACM, and SSH;
4. can reboot to bootloader and recovery without a physical reset;
5. reproduces from tracked pmaports packages without local binary payloads.
