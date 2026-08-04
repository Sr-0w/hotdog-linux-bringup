# OnePlus 7T Pro Mainline 6.16 Reference Kernel

This aport packages the first source-reproducible kernel configuration known to
boot directly from the HD1913 bootloader into a postmarketOS root filesystem.
The hardware run reached the native display console, USB NCM and ACM gadget
functions, and SSH without using a downstream bridge kernel or `kexec`.
Revision `r4` also enables and hardware-validates the Samsung S6SY761
touchscreen, including multitouch coordinate and pressure events. Revision
`r5` enables the Adreno 640 and GMU and validates the resulting render node
with the upstream MSM DRM driver and real Turnip Vulkan submissions. Revision
`r6` adds the PM8150 Volume Down and Volume Up input paths while preserving the
validated touchscreen, GPU, USB, storage, and display contracts. Revision `r7`
starts directly from that source and enables only the PM8150B fuel gauge and
SMB5 charger device-tree nodes.

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
- PM8150 PON provides Power and Volume Down, while PM8150 GPIO 6 provides the
  active-low, pulled-up Volume Up input through `gpio-keys`.
- A 4085 mAh battery description supplies conservative charge limits to the
  enabled PM8150B fuel gauge and SMB5 charger.
- The device tree is built entirely from source. No packaged DTB is rewritten
  with `fdtput` or replaced by a prebuilt binary.

`validate-mainline616-build.sh` checks the direct-entry Image window and every
DT invariant that was present during the successful hardware run. The package
build fails if one of those invariants changes.

## Strict build evidence

Two accepted `r7` strict pmbootstrap builds completed on 2026-08-04. Both
printed `hotdog mainline 6.16 build contract: PASS` before packaging and
produced byte-identical APKs:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r7.apk` | 25,535,717 bytes | `7443a6e60eea3001370901a3a39064fd4a72909175a34cb99a6f9ee8b05b2e84` |
| `boot/vmlinuz` | 27,572,232 bytes | `a295b1c7723c73aaabf546697a5c1f393092771c6164746f72426510f0b1c101` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 139,672 bytes | `17e7dabb69f8376cbd294e82b01fcbd797d7bcc05d5f5a31b42939bf86ddad19` |

The exact APK kernel and DTB were assembled with the validated pmaports
initramfs, written to `boot_b`, read back completely, and booted directly on
the HD1913. The 96 MiB boot image and full partition readback both have SHA256
`dbc5210987b791774e67e7a6ad5fd796ecf950fca5ebe8e0a414f6112009c29f`.
USB networking, SSH, and the S6SY761 touchscreen remained available. Power,
Volume Down, and Volume Up registered with their expected Linux key codes. The
Adreno driver bound, exposed `/dev/dri/renderD128`, loaded GMU firmware
v2.0.261, and completed two headless Vulkan workloads through Turnip without a
GPU, GMU, or IOMMU fault.
The same boot exposes `pm8150b-charger` and `qcom-battery`; a 60-second trace
recorded 31 samples while USB networking and SSH remained available.

## Temporary bring-up constraints

The UFS and QUP Apps SMMU links and the UFS inline-crypto reference are disabled
in the device tree while their native paths are being repaired. Compatibility
symbols for the filtered OnePlus DTBO are also temporary. These constraints are
documented in source so each can be removed independently and tested.

This device-specific package is a reference point, not the intended final
pmaports architecture. Once the remaining hardware paths are stable, the
OnePlus changes should move to the shared SM8150 kernel package and the normal
postmarketOS device package.
