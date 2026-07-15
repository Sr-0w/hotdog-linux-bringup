# K1 kernel package build evidence

> [!IMPORTANT]
> The r5 section is the current package-build evidence. The r4 section remains
> the latest double-build reproducibility result. The r3 section records the
> intermediate diagnosis. Historical r0 facts must not be attributed to later
> package revisions.

## Current r5 build evidence

One strict `6.17.0-r5` pmbootstrap build completed packaging and repository
indexing. Pmbootstrap then reported a busy `ccache` mount during strict chroot
cleanup; this occurred after abuild logged `Build complete` and does not affect
the APK below. The r5 payload has not yet been booted on hardware or built a
second time.

| Item | Exact r5 result |
|---|---|
| APK | `27,172,103` bytes; SHA256 `f3083fd4c6af13be364eb0317873ee3a6f3690c5acb3a9e111c65b26b1746dd6` |
| `boot/vmlinuz` | `28,901,384` bytes; SHA256 `417475432ab2db0a84a4a13d3b5c3dfd6b2c3b60236b58467fca4aafb110b118` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | `136,159` bytes; SHA256 `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440` |
| `usr/share/kernel/oneplus-hotdog-mainline617-k1/kernel.release` | `14` bytes; value `6.17.0-sm8150`; SHA256 `19fc01a849ff035de7cf482b0154ea41d7c95e1a1d581aee86a4c875857868c0` |
| `usr/lib/modules/6.17.0-sm8150/modules.builtin` | `25,109` bytes; SHA256 `b0cbb60effb341e6d542a1c7559c1c4cec7961c73132dc792f20bacf320fc1c0` |
| `.PKGINFO` | `583` bytes; SHA256 `d541852cf41e8a231d526f4a617186af8261749cc461431d5bdd06371134cd7d`; `builddate = 1761609785` |

The extracted embedded kernel config confirms `CONFIG_QCOM_WDT=y`,
`CONFIG_RAID6_PQ=y`, and `CONFIG_RAID6_PQ_BENCHMARK=n`. The package config
SHA256 is `b41e8d59af26d6f8adfa7cb41d624bd8da63d45b4bc38494849aa77ba8114895`.
A separate direct-boot checkpoint image using the same RAID6 delta reached the
checkpoint after `raid6_select_algo` on hardware. That validates the config
workaround, not the complete r5 package payload.

## Current r4 double-build evidence

Two `6.17.0-r4` builds produced byte-identical APKs in the tested pmbootstrap
environment. The result is exact for that environment only; it is not evidence
of cross-toolchain reproducibility and the r4 payload has not been tested on
hardware.

| Item | Exact r4 result |
|---|---|
| APK, both builds | `27,172,035` bytes; SHA256 `74d7cff718be9a06b8858360fe56c1ccd8d1fd7653151546b0480029694d803e` |
| `boot/vmlinuz` | `28,901,384` bytes; SHA256 `7fba453fd960515b526e7f562b9c682078ad800f27e5861db431ad9d7d4532b5` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | `136,159` bytes; SHA256 `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440` |
| `usr/share/kernel/oneplus-hotdog-mainline617-k1/kernel.release` | `14` bytes; value `6.17.0-sm8150`; SHA256 `19fc01a849ff035de7cf482b0154ea41d7c95e1a1d581aee86a4c875857868c0` |
| `usr/lib/modules/6.17.0-sm8150/modules.builtin` | `25,109` bytes; SHA256 `b0cbb60effb341e6d542a1c7559c1c4cec7961c73132dc792f20bacf320fc1c0` |
| `.PKGINFO` | `583` bytes; SHA256 `60950d9aaa3fd4b559b19a02bfb9dddd3993e2f0b37a1097afbfaa4c4ba02a2c`; `builddate = 1761609785` |

The two APKs compare equal byte for byte. All archive-member mtimes are fixed
to `2025-10-28 00:03:05 UTC`, the timestamp represented by
`SOURCE_DATE_EPOCH=1761609785`. The APK contains no top-level `lib/` member and
no `qcom-wdt.ko` payload member. Its `modules.builtin` file contains
`kernel/drivers/watchdog/qcom-wdt.ko`, which records that the Qualcomm watchdog
is built into the kernel through `CONFIG_QCOM_WDT=y` rather than shipped as a
loadable module.

The r4 `.PKGINFO` records `pkgver = 6.17.0-r4`, `arch = aarch64`, and
`commit = -dirty`. The reproducibility result therefore does not claim a clean
source-control identity.

## Intermediate r3 evidence

Two r3 builds produced identical DTB, modules, and `modules.builtin` payloads,
but different APK and `vmlinuz` bytes. The `vmlinuz` difference is limited to
29 bytes from the GNU build ID and three initramfs CPIO mtimes; `.PKGINFO`
build dates also differ. r3 is preserved as intermediate diagnostic evidence,
not as a byte-reproducible package result.

## Historical r0 inputs

The remaining evidence records the successful offline r0 `pmbootstrap` build
of the experimental `linux-oneplus-hotdog-mainline617-k1` package and pins the
exact r0 APK and kernel payloads produced by that build.

| Item | Value |
|---|---|
| sm8150 Linux source commit | `379d8fe35c7ca685a650bd82fd023af0ea3f0de0` |
| captured K1 config SHA256 | `af45c52e0176343e6696dbed5f6a65fd51af639441598ac9d010318b813ee185` |
| historical K1 Image SHA256 | `48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83` |

The captured config is the same hash recorded for the historical K1 artifact.
The package reconstructs the captured K1 build inputs from public source plus
the captured configuration and tracked patches. Functional equivalence remains
a hardware-validation target rather than a conclusion of this package build.

## Historical r0 pmbootstrap package result

The successful build produced this r0 artifact:

| Property | Value |
|---|---|
| APK | `pmbootstrap-work/packages/edge/aarch64/linux-oneplus-hotdog-mainline617-k1-6.17.0-r0.apk` |
| APK size | `27,176,454` bytes |
| Installed size (`.PKGINFO`) | `97,247,600` bytes |
| SHA256 | `7270ec739af5a34402737a990b7a1e5ca945484901e554ad305b3fb7a0173287` |
| Package version | `6.17.0-r0` |
| Architecture | `aarch64` |
| `.PKGINFO` commit | `-dirty` |

Direct inspection of the APK verified these installed payloads:

| APK member | Verification |
|---|---|
| `boot/vmlinuz` | `28,901,384` bytes; SHA256 `e9e2249b4ea8a749ceef7fb481a214fb0ac049f17a0a78ba8699e41d1535af5b` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | `136,171` bytes; SHA256 `44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49` |
| `usr/share/kernel/oneplus-hotdog-mainline617-k1/kernel.release` | `6.17.0-sm8150` |
| `usr/lib/modules/6.17.0-sm8150/kernel/drivers/watchdog/qcom-wdt.ko` | present; `13,424` bytes; SHA256 `159d8aa617cae6bf05718baf88f4bb7f1b8ff2a7ef6e729d0c4325b25b1d5268` |

The package metadata was generated by `abuild 3.18.0_rc2-r0`. The final forced
lax build completed in 1 minute 24 seconds and passed the package postcheck with
all kernel modules under `usr/lib/modules`; the APK has no top-level `lib/`
members. The r0 pmaports input therefore builds through `pmbootstrap` and
produces an inspectable r0 APK with the expected K1 base DTB and watchdog
module.

The APK metadata contains `commit = -dirty`. This records that the pmaports
checkout was dirty while packaging (the new aport itself was still untracked);
it is not presented as a clean source-control identity. The
packaged `kernel.release` is `6.17.0-sm8150` and does not contain a `-dirty`
suffix.

## Historical r0 package lint

`apkbuild-lint` also completed successfully inside the native pmbootstrap
chroot. The invocation declared `pmb:cross-native` and
`pmb:kconfigcheck-nftables` through `CUSTOM_VALID_OPTIONS`; these are
pmbootstrap/pmaports extensions rather than Alpine base options. With those
extensions recognized, the linter reported no package issue.

## Historical r0 manual rebuild result

A clean manual kernel rebuild completed for:

- `Image`
- modules
- device trees

The rebuilt `Image` recorded for this check was:

| Property | Value |
|---|---|
| SHA256 | `0aacf50f0b949f22902d89fb9dfd961433cb957453f50f90bca71186d4b3301e` |
| Size | `28,901,384` bytes |
| First 64 bytes vs. historical K1 Image | identical |

This validates the source/config/patch path far enough to build the kernel
payload family. It does not claim byte-for-byte reproduction of the historical
K1 `Image`.

## Historical r0 validation scope

The successful APK build validates the package path and the payload hashes
above. It does not by itself claim hardware validation or byte-for-byte
reproduction of the historical K1 `Image`.

The earlier manually rebuilt `Image` hash differs from the historical K1 hash.
Embedded kernel metadata and toolchain-dependent output remain expected
contributors, including build timestamp, build counter, local version/dirty
suffix, compiler and linker identity, and related generated strings. This
record does not prove that those are the only byte differences.
