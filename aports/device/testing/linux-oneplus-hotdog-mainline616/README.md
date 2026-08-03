# OnePlus 7T Pro Mainline 6.16 Reference Kernel

This aport packages the first source-reproducible kernel configuration known to
boot directly from the HD1913 bootloader into a postmarketOS root filesystem.
The hardware run reached the native display console, USB NCM and ACM gadget
functions, and SSH without using a downstream bridge kernel or `kexec`.

## Source contract

- Kernel base: ClearStaff Linux 6.16 commit
  `403b56c33e2ccdda25d90378970a5e5b928dee19`.
- Generic DWC3, USB gadget, and IOMMU drivers remain unchanged from that base.
- The DWC3 stream keeps the upstream Apps SMMU binding and boots with a
  translated domain (`iommu.passthrough=0`).
- The native Samsung DSC panel, TE signal, and 16x32 framebuffer console are
  built in.
- The device tree is built entirely from source. No packaged DTB is rewritten
  with `fdtput` or replaced by a prebuilt binary.

`validate-mainline616-build.sh` checks the direct-entry Image window and every
DT invariant that was present during the successful hardware run. The package
build fails if one of those invariants changes.

## Strict build evidence

The first clean strict pmbootstrap build completed on 2026-08-03 and printed
`hotdog mainline 6.16 build contract: PASS` before packaging:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r0.apk` | 25,534,610 bytes | `ee5c55ddde8c9a385d1b11af799df2a373110dabc4441614b33b8712877408ce` |
| `boot/vmlinuz` | 27,572,232 bytes | `ee3abf18421b49462b5afd2f4e923fd97e6f3cdc13a06e4a1948e18e306b69d5` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 138,194 bytes | `d043e06a4fa685ef4527872bddc0788f82ff55ef4ad98358ec3b111da9b4379f` |

This validates package reproducibility from the pinned inputs and the encoded
hardware contract. It does not yet claim that this exact APK-derived payload
has booted on hardware.

## Temporary bring-up constraints

The UFS and QUP Apps SMMU links and the UFS inline-crypto reference are disabled
in the device tree while their native paths are being repaired. Compatibility
symbols for the filtered OnePlus DTBO are also temporary. These constraints are
documented in source so each can be removed independently and tested.

This device-specific package is a reference point, not the intended final
pmaports architecture. Once the remaining hardware paths are stable, the
OnePlus changes should move to the shared SM8150 kernel package and the normal
postmarketOS device package.
