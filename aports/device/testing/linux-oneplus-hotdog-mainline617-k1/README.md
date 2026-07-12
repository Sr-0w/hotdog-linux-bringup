# linux-oneplus-hotdog-mainline617-k1

Experimental forensic package derived from the historical OnePlus 7T Pro
mainline K1 kernel. The source commit and patch inputs are pinned, with one
intentional config delta for r4: the Qualcomm watchdog is built into the kernel.

The package-built r4 kernel and DTB are offline reproduction artifacts. This
README makes no claim that either artifact has been validated on hardware.

## Historical reference

- Source: `https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux`
- Commit: `379d8fe35c7ca685a650bd82fd023af0ea3f0de0`
- Historical Image SHA256:
  `48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83`
- Historical config SHA256:
  `af45c52e0176343e6696dbed5f6a65fd51af639441598ac9d010318b813ee185`
- Historical release:
  `6.17.0-sm8150-g379d8fe35c7c-dirty`

## r4 inputs

- The r4 config SHA256 is
  `dac751c53bb9451fc8c03c3599f2912b544466aa9e9d3901179ff58e841f488d`.
  It differs intentionally from the historical config at one setting:
  `CONFIG_QCOM_WDT=m` became `CONFIG_QCOM_WDT=y`. Consequently, `qcom-wdt` is
  built into the kernel and no `qcom-wdt.ko` module is expected.
- `0001-arm64-hotdog-use-android-entry-layout.patch` is copied from
  the top-repository patch `patches/experimental-android-kernel-entry-layout.patch`.
- `0002-input-fts-fix-strict-prototypes.patch` is copied from
  the top-repository patch `patches/mainline-fts-strict-prototypes.patch`.
- `0003-power-supply-idtp9418-include-gpio-consumer.patch` is a package-local
  build fix for the module build of the captured K1 config.
- `0004-arm64-dts-qcom-add-oneplus-hotdog.patch` restores the exact hotdog DTS
  and Makefile target used by K1. Its source DTS SHA256 is
  `d33fb0e36a065f6f2b09e5436e89ef2bb0a80d79f9633a2d4b800f549248f51a`.

The entry-layout patch provides the non-EFI Android-style arm64 Image header
used by the K1 direct-boot experiments. The FTS patch is required for LLVM/clang
strict-prototype builds. The idtp9418 patch adds the missing GPIO consumer API
include required by `CONFIG_CHARGER_IDTP9418=m`.

## Reproducibility controls and r4 result

R4 exports `SOURCE_DATE_EPOCH=1761609785` at APKBUILD scope so abuild and every
make invocation inherit the source commit time. The kernel build also receives
that epoch explicitly alongside a BusyBox-compatible `KBUILD_BUILD_TIMESTAMP`
(`2025-10-28 00:03:05`), user `postmarketOS`, host `pmaports`, and the
package-derived `KBUILD_BUILD_VERSION`. In the UTC build environment, that
BusyBox-compatible timestamp resolves to the same `1761609785` epoch and the
same `Tue Oct 28 00:03:05 UTC 2025` source time; only its spelling differs.

Two independent r4 builds under the same toolchain and dependency set produced
byte-identical APKs and byte-identical extracted trees. Their exact SHA256 values
are:

- APK: `74d7cff718be9a06b8858360fe56c1ccd8d1fd7653151546b0480029694d803e`
- `boot/vmlinuz`: `7fba453fd960515b526e7f562b9c682078ad800f27e5861db431ad9d7d4532b5`
- hotdog DTB: `cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440`
- `kernel.release`: `19fc01a849ff035de7cf482b0154ea41d7c95e1a1d581aee86a4c875857868c0`
- `modules.builtin`: `b0cbb60effb341e6d542a1c7559c1c4cec7961c73132dc792f20bacf320fc1c0`
- `.PKGINFO`: `60950d9aaa3fd4b559b19a02bfb9dddd3993e2f0b37a1097afbfaa4c4ba02a2c`

Both `.PKGINFO` files record `builddate=1761609785`, and all packaged payload
mtimes use that epoch. This validates byte reproducibility for the tested r4
environment; it does not claim reproducibility across different toolchains or
dependency sets, nor hardware validation.

The resulting Image is not expected to match the historical Image because the
config and historical local metadata differ.

## r3 reproducibility finding

Two independent r3 APKs proved that the transformed hotdog DTB (`cf63ae7f...`),
`kernel.release`, `modules.builtin`, and every loadable module were byte-identical.
Their `vmlinuz` files had the same size but differed by exactly 29 bytes: a
20-byte GNU build-id and three 3-byte differences in the embedded initramfs CPIO
mtime fields for `dev`, `dev/console`, and `root`.

The r3 `.PKGINFO` build dates were `1783841052` and `1783842475`. With no
explicit `SOURCE_DATE_EPOCH`, abuild 3.18 `set_source_date` selected the mtime of
the copied APKBUILD in the dirty checkout. That varying epoch propagated to the
CPIO mtimes and therefore to the GNU build-id. R4 pins the epoch to remove this
specific source of variation, and the byte-identical r4 double build confirms
that result for the tested environment.

## Device tree reproduction

With the r4 config and pinned source commit, the hotdog DTS patch first builds
`qcom/sm8150-oneplus-hotdog.dtb` with SHA256
`44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49`.

During packaging, `transform-k1-dtb.sh` requires that exact input hash, applies
the recorded lowbank, firmware-gap, UFS/QUP SMMU bypass, UFS ICE removal, and
DWC3 SMMU bypass mutations, then requires the exact output SHA256
`cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440`.
The package replaces the hotdog DTB at its installed path with that final
output; it does not retain the `440525...` base as a second hotdog DTB.

The byte-exact output depends on the serialization produced by `fdtput` from
the `dtc` build dependency. The transform is deliberately fail-closed: a
different input or serialized output aborts packaging instead of publishing a
DTB whose hash is not the recorded K1 value. A future `dtc`/`libfdt` change can
therefore require review even when its semantic DTB mutations are equivalent.
