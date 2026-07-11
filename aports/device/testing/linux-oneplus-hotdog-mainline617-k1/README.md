# linux-oneplus-hotdog-mainline617-k1

Experimental forensic package for the historical OnePlus 7T Pro mainline K1
kernel.

This package reconstructs the captured K1 source/config/patch inputs and builds
the resulting kernel payloads. Functional equivalence remains a hardware test;
the package does not promise a byte-identical rebuild of the historical
`Image`.

## Historical reference

- Source: `https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux`
- Commit: `379d8fe35c7ca685a650bd82fd023af0ea3f0de0`
- Historical Image SHA256:
  `48ac790a9f15dbf3e976557d1baee6a72b847fefed17fed9e700424d91e3fa83`
- Historical config SHA256:
  `af45c52e0176343e6696dbed5f6a65fd51af639441598ac9d010318b813ee185`
- Historical release:
  `6.17.0-sm8150-g379d8fe35c7c-dirty`

## Captured local inputs

- `config-oneplus-hotdog-mainline617-k1.aarch64` is captured byte-for-byte from
  the K1 artifact config. Its SHA256 is
  `af45c52e0176343e6696dbed5f6a65fd51af639441598ac9d010318b813ee185`.
- `0001-arm64-hotdog-use-android-entry-layout.patch` is copied from
  the top-repository patch `patches/experimental-android-kernel-entry-layout.patch`.
- `0002-input-fts-fix-strict-prototypes.patch` is copied from
  the top-repository patch `patches/mainline-fts-strict-prototypes.patch`.
- `0003-power-supply-idtp9418-include-gpio-consumer.patch` is a package-local
  build fix for the module build of the captured K1 config.
- `0004-arm64-dts-qcom-add-oneplus-hotdog.patch` restores the exact hotdog DTS
  and Makefile target used by K1. Its source DTS SHA256 is
  `d33fb0e36a065f6f2b09e5436e89ef2bb0a80d79f9633a2d4b800f549248f51a`.

The entry-layout patch is required for the non-EFI Android-style arm64 Image
header used by the K1 direct-boot experiments. The FTS patch is required for
LLVM/clang strict-prototype builds. The idtp9418 patch adds the missing GPIO
consumer API include required by `CONFIG_CHARGER_IDTP9418=m`.

## Device tree reproduction

With the captured config and pinned source commit, the hotdog DTS patch builds
`qcom/sm8150-oneplus-hotdog.dtb` with SHA256
`44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49`.
That output is byte-identical to the base DTB used by the hardware-tested K1
transform chain.

## Non-identical metadata

The historical Image embedded local build metadata, including toolchain string,
build counter, timestamp, and dirty git release suffix.

A normal pmaports build may therefore produce a different Image SHA256 even
when the source, patches, and kernel config are correct.
