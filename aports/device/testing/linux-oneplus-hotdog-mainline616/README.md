# OnePlus 7T Pro Mainline 6.16 Reference Kernel

This aport packages the first source-reproducible kernel configuration known to
boot directly from the HD1913 bootloader into a postmarketOS root filesystem.
The hardware run reached the native display console, USB NCM and ACM gadget
functions, and SSH without using a downstream bridge kernel or `kexec`.
Revision `r4` also enables and hardware-validates the Samsung S6SY761
touchscreen, including multitouch coordinate and pressure events.

## Source contract

- Kernel base: ClearStaff Linux 6.16 commit
  `403b56c33e2ccdda25d90378970a5e5b928dee19`.
- Generic DWC3, USB gadget, and IOMMU drivers remain unchanged from that base.
- The DWC3 stream keeps the upstream Apps SMMU binding and boots with a
  translated domain (`iommu.passthrough=0`).
- The native Samsung DSC panel, TE signal, and 16x32 framebuffer console are
  built in.
- QUPv3 wrapper 2, GPI DMA 2, I2C17, and the schema-complete S6SY761 node are
  enabled for the HD1913 touchscreen.
- The device tree is built entirely from source. No packaged DTB is rewritten
  with `fdtput` or replaced by a prebuilt binary.

`validate-mainline616-build.sh` checks the direct-entry Image window and every
DT invariant that was present during the successful hardware run. The package
build fails if one of those invariants changes.

## Strict build evidence

The accepted strict pmbootstrap build completed on 2026-08-04 and printed
`hotdog mainline 6.16 build contract: PASS` before packaging:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r4.apk` | 25,534,903 bytes | `ca4cc9ff32caac1fe1126966e681ffcf1ec827bd5d96450f81a500df63903664` |
| `boot/vmlinuz` | 27,572,232 bytes | `df3f119058c320e09c7372ee3cdcd5b90dd2c088d4f14e4af70831d5df7843f2` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 138,574 bytes | `ef22a1e539e28af028e48d0154ae091de79da358dd3854797a86c403dd520af3` |

Two strict builds produced the same APK hash. The exact APK kernel and DTB were
then assembled with the validated pmaports initramfs, written to `boot_b`, read
back completely, and booted directly on the HD1913. USB networking and SSH
returned, and `s6sy761` registered as I2C client `0-0048` and input `event1`.
Taps, drags, pressure, and multiple contact slots produced live input events.

## Temporary bring-up constraints

The UFS and QUP Apps SMMU links and the UFS inline-crypto reference are disabled
in the device tree while their native paths are being repaired. Compatibility
symbols for the filtered OnePlus DTBO are also temporary. These constraints are
documented in source so each can be removed independently and tested.

This device-specific package is a reference point, not the intended final
pmaports architecture. Once the remaining hardware paths are stable, the
OnePlus changes should move to the shared SM8150 kernel package and the normal
postmarketOS device package.
