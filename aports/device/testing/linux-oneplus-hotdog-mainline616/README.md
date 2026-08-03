# OnePlus 7T Pro Mainline 6.16 Reference Kernel

This aport packages the first source-reproducible kernel configuration known to
boot directly from the HD1913 bootloader into a postmarketOS root filesystem.
The hardware run reached the native display console, USB NCM and ACM gadget
functions, and SSH without using a downstream bridge kernel or `kexec`.
Revision `r4` also enables and hardware-validates the Samsung S6SY761
touchscreen, including multitouch coordinate and pressure events. Revision
`r5` enables the Adreno 640 and GMU and validates the resulting render node
with the upstream MSM DRM driver and real Turnip Vulkan submissions.

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
- The SM8150 Adreno 640 and GMU are enabled with the handset-specific signed
  ZAP firmware path. Their existing upstream SMMU, OPP, power-domain, clock,
  interconnect, and reserved-memory descriptions remain unchanged.
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
| `linux-oneplus-hotdog-mainline616-6.16.0-r5.apk` | 25,534,915 bytes | `276be937d54b8d7120c3665c202f06f0a0231e56058e0bf221e6aba5c2e200fb` |
| `boot/vmlinuz` | 27,572,232 bytes | `c7caaefb00dfc7eac00d57bb151ebddfc4cd4b32ab0c18b1e0ba2d11fb63cb65` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 138,618 bytes | `45512bdf5f4126c49ca28c0152ec6e2c1a8848dd872593f6be2c33d02b97bf55` |

Two strict builds produced the same APK hash. The exact APK kernel and DTB were
then assembled with the validated pmaports initramfs, written to `boot_b`, read
back completely, and booted directly on the HD1913. The 96 MiB boot image and
full partition readback both have SHA256
`14da6a2e2f0b49b85eb1431f1c9e9e32a08250fa42149ebfd50881970bf9cf44`.
USB networking, SSH, and the S6SY761 touchscreen remained available. The
Adreno driver bound, exposed `/dev/dri/renderD128`, loaded GMU firmware
v2.0.261, and completed two headless Vulkan workloads through Turnip without a
GPU, GMU, or IOMMU fault.

## Temporary bring-up constraints

The UFS and QUP Apps SMMU links and the UFS inline-crypto reference are disabled
in the device tree while their native paths are being repaired. Compatibility
symbols for the filtered OnePlus DTBO are also temporary. These constraints are
documented in source so each can be removed independently and tested.

This device-specific package is a reference point, not the intended final
pmaports architecture. Once the remaining hardware paths are stable, the
OnePlus changes should move to the shared SM8150 kernel package and the normal
postmarketOS device package.
