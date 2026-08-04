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
SMB5 charger device-tree nodes. Revision `r8` corrects the charger driver's
SMB2/SMB5 conversion mismatch and programs conservative battery limits before
enabling charging or USB input.

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
- SMB2 and SMB5 use their generation-specific voltage and current encodings.
  SMB5 probe keeps charging and USB input suspended until 4.40 V, 1.50 A, and
  500 mA limits have been programmed successfully.
- The device tree is built entirely from source. No packaged DTB is rewritten
  with `fdtput` or replaced by a prebuilt binary.

`validate-mainline616-build.sh` checks the direct-entry Image window and every
DT invariant that was present during the successful hardware run. The package
build fails if one of those invariants changes.

## Strict build evidence

Two accepted `r8` strict pmbootstrap builds completed on 2026-08-04. Each
started from reset buildroots, printed
`hotdog mainline 6.16 build contract: PASS` before packaging, and produced a
byte-identical APK:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r8.apk` | 25,536,679 bytes | `668c87bfb2e5f25b7e910e4c471414c85053d33e2fd52d9041136716a5967650` |
| `boot/vmlinuz` | 27,572,232 bytes | `4bdf4c4c1e2fd8ffaa5428695ab51bbf7a9a7364eba84eb632250d9436575446` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 139,672 bytes | `17e7dabb69f8376cbd294e82b01fcbd797d7bcc05d5f5a31b42939bf86ddad19` |

The exact APK kernel and DTB were assembled with the validated pmaports
initramfs, written to `boot_b`, read back completely, and booted directly on
the HD1913. The 96 MiB boot image and full partition readback both have SHA256
`32d5e2a4cea4d31c4200dbf6da82abfc7e2a25b717f3a3c7a017a688c3cf6376`.
The fresh boot reported kernel build `#9-oneplus-hotdog-mainline616`, returned
USB networking and SSH, and retained the previously validated touchscreen,
keys, and GPU contracts.

Direct PMIC register reads before and after a 180-second trace confirmed float
voltage `0x50` (4.40 V), fast-charge current `0x1e` (1.50 A), and USB input
limit `0x0a` (500 mA). All 61 samples reported both supplies as charging. The
battery remained between 4,407,459 and 4,408,680 uV without crossing the
4.42 V guard. A later transition to Qualcomm `900e` remains under
investigation. A read-only Sahara capture recovered the 4 KiB ramoops console
and pmsg zones; they contain a normal boot through OpenRC handoff and no panic
or oops before the abrupt transition.

## Temporary bring-up constraints

The UFS and QUP Apps SMMU links and the UFS inline-crypto reference are disabled
in the device tree while their native paths are being repaired. Compatibility
symbols for the filtered OnePlus DTBO are also temporary. These constraints are
documented in source so each can be removed independently and tested.

This device-specific package is a reference point, not the intended final
pmaports architecture. Once the remaining hardware paths are stable, the
OnePlus changes should move to the shared SM8150 kernel package and the normal
postmarketOS device package.
