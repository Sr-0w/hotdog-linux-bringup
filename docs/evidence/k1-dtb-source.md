# K1 hotdog DTB source reproduction

The hardware-tested K1 base DTB is now reproducible from tracked source. The
source patch is [`patches/mainline-hotdog-k1-dts.patch`](../../patches/mainline-hotdog-k1-dts.patch).

## Pinned inputs

| Input | Value |
|---|---|
| Kernel repository | `https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux` |
| Kernel commit | `379d8fe35c7ca685a650bd82fd023af0ea3f0de0` |
| Hotdog DTS SHA256 | `d33fb0e36a065f6f2b09e5436e89ef2bb0a80d79f9633a2d4b800f549248f51a` |
| Captured K1 config SHA256 | `af45c52e0176343e6696dbed5f6a65fd51af639441598ac9d010318b813ee185` |
| Expected base DTB SHA256 | `44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49` |

The patch adds `sm8150-oneplus-hotdog.dts`, its Makefile target, and the
per-DTB `-@` flag needed to retain symbols for the transform workflow. Its
`sm8150-oneplus-common.dtsi` dependency is already present at the pinned
kernel commit.

## Clean rebuild

The patch was applied to a clean checkout of the pinned commit, then the
captured K1 config was used with:

```sh
make O="$out" ARCH=arm64 LLVM=1 olddefconfig
make O="$out" ARCH=arm64 LLVM=1 qcom/sm8150-oneplus-hotdog.dtb
```

The resulting
`arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dtb` has SHA256
`44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49`.
This is byte-identical to the recorded K1 base DTB, closing the previously
missing source link.

## Device identity note

The physical test handset is rear-labelled HD1913. Its recovery and vendor
software report HD1911 while exposing the same `hotdog` project identifiers
used by this source: project `19801`, DTB index `12`, DTBO index `5`, and
hardware version `14`. The historical HD1911 wording is therefore preserved
inside the hash-pinned source. Results must not be generalized to every hotdog
variant without separate validation.

## Transform chain

The source-built `440525...` DTB is the input to
`scripts/build-mainline-k1-dtb-chain.sh`. The ordered lowbank, firmware-gap,
SMMU, ICE, and DWC3 bring-up transforms reproduce the hardware-tested final
DTB:

```text
440525... -> e58d41... -> d9d31d... -> d8cfc7... -> 7334f7... -> cf63ae...
```

The final SHA256 is
`cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440`.
The lowbank and SMMU/ICE removals remain temporary bring-up constraints, not
upstreamable fixes. PON reboot-mode properties are tracked separately and are
not part of the exact K1 base.
