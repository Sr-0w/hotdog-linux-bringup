# Mainline 6.16 pmaports reference package

Date: 2026-08-03

## Result

The first strict pmbootstrap build of
`linux-oneplus-hotdog-mainline616-6.16.0-r0` completed successfully. The aport
rebuilds the kernel Image, modules, and `sm8150-oneplus-hotdog.dtb` from pinned
public source. It does not inject or rewrite a binary DTB.

The build ran from a fresh strict buildroot with:

```sh
./scripts/pmbootstrap-hotdog.sh -j 12 --details-to-stdout \
  build --arch aarch64 linux-oneplus-hotdog-mainline616
```

The build completed in 13 minutes 52 seconds. Before packaging, the integrated
validator reported:

```text
hotdog mainline 6.16 build contract: PASS
```

## Pinned inputs

- ClearStaff Linux 6.16 commit:
  `403b56c33e2ccdda25d90378970a5e5b928dee19`.
- Public patch series: `0001` through `0015` in the aport.
- Full V43 kernel configuration:
  `config-oneplus-hotdog-mainline616.aarch64`.
- DT source contract: low-bank memory window, firmware no-map gap, native
  Samsung DSC panel, TE GPIO, ramoops, temporary UFS/QUP SMMU bypasses, UFS ICE
  removal, and translated DWC3 Apps SMMU stream `0x140`.

The build also corrected the output blob index in patch `0006` from the
ambiguous all-zero deletion marker to the actual post-patch blob prefix
`21f7ffe2854a`. This changes no source payload; it makes the patch portable to
the `patch` implementation used by abuild.

## Output identities

| Output | Size | SHA256 |
|---|---:|---|
| APK | 25,534,610 bytes | `ee5c55ddde8c9a385d1b11af799df2a373110dabc4441614b33b8712877408ce` |
| `boot/vmlinuz` | 27,572,232 bytes | `ee3abf18421b49462b5afd2f4e923fd97e6f3cdc13a06e4a1948e18e306b69d5` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 138,194 bytes | `d043e06a4fa685ef4527872bddc0788f82ff55ef4ad98358ec3b111da9b4379f` |

The packaged DTB is byte-identical to the independently built source-DTS
candidate used for offline overlay and invariant validation.

## What this proves

- The V43 kernel contract is expressible as a normal source aport.
- All 15 public patches apply in a strict pmbootstrap buildroot.
- The kernel, modules, panel driver, DWC3/NCM path, UFS path, SMMU support, and
  source-generated hotdog DTB compile together.
- The packaged Image header/window and required configuration values pass the
  hardware-contract validator.
- The source-generated DTB carries the memory, display, storage, ramoops, and
  translated DWC3 invariants validated during the V43 bring-up.

## What remains unproven

This exact package payload has not yet been installed or booted on the phone.
The next gate is a complete pmbootstrap initramfs, boot image, and rootfs build,
followed by a guarded write/readback and one hardware boot. The temporary UFS
DMA32 constraint, UFS/QUP SMMU bypasses, ICE removal, filtered-DTBO symbols,
and device-specific kernel package remain bring-up debt rather than an
upstream submission design.
