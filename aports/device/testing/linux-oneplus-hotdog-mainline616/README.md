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
validated touchscreen, GPU, USB, storage, and display contracts.

Revision `r10` adds a preflight-only PM8150B fuel-gauge and charger candidate.
It uses conservative 4.40 V, 1.50 A battery limits and a 500 mA initial USB
input limit, corrects SMB2/SMB5 selector conversions, and leaves charging
disabled on every probe failure. It also derives the arm64 Image window from
the linked kernel size. This revision is reproducibly built but is not yet
hardware-validated; the accepted runtime baseline remains `r6`.

Revision `r11` stages modem bring-up independently from WiFi. It restores the
2 MiB RMTFS region at `0xf2901000`, enables MPSS with the packaged hotdog modem
firmware, and deliberately keeps WCN3990 disabled. The OpenRC device package
starts `rmtfs` with its default no-write policy. This revision remains a
preflight candidate until `r10` passes its power gate and MPSS is then tested
on hardware.

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
- MPSS uses the handset-specific modem firmware and the downstream-compatible
  high RMTFS address. WiFi remains disabled for the isolated MPSS gate.
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
| `linux-oneplus-hotdog-mainline616-6.16.0-r6.apk` | 25,535,120 bytes | `17af600197825164ceb791606cbb00cd7f19d587746432fd58140c5d24c85e6e` |
| `boot/vmlinuz` | 27,572,232 bytes | `b35176a252b10d51d33b182e4ca7e1ab4ceadccf191cba987a359c0093a2f5d5` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 139,174 bytes | `fec8bf455c4c922737d7676d9dc96e9220ccea3eb87297665c8b19bee577e106` |

Two strict builds produced the same APK hash. The exact APK kernel and DTB were
then assembled with the validated pmaports initramfs, written to `boot_b`, read
back completely, and booted directly on the HD1913. The 96 MiB boot image and
full partition readback both have SHA256
`33e20fce76b38122fe4b5fb8427eab044e7c594649e105e20ff9284e4e570f2e`.
USB networking, SSH, and the S6SY761 touchscreen remained available. Power,
Volume Down, and Volume Up registered with their expected Linux key codes. The
Adreno driver bound, exposed `/dev/dri/renderD128`, loaded GMU firmware
v2.0.261, and completed two headless Vulkan workloads through Turnip without a
GPU, GMU, or IOMMU fault.

The current `r11` preflight build is also reproducible. One strict build used
the normal cache and another used `--no-ccache`; both produced the same
25,502,518-byte APK with SHA256
`b499a6b3cf488e15d743e66a0965a74e30771e0cea6941040327498af154be6c`.
Its kernel and DTB hashes are respectively
`89c6a92678c39fcd7f8e540b8f3706e9e5118b25de2b6842f134fd967a9fa243`
and `652bb1e48d974724ff0168ff40b60d54596d60b3a6dd232883c0ceb4abba291f`.
The resulting deterministic AVB image has SHA256
`4a4bffb60ce744f5fd5fc4070808699fb573a9350f24e60a5d59535aef5dc849`.
These hashes are static preflight evidence only; `r11` has not been accepted on
hardware.

## Temporary bring-up constraints

The UFS and QUP Apps SMMU links and the UFS inline-crypto reference are disabled
in the device tree while their native paths are being repaired. Compatibility
symbols for the filtered OnePlus DTBO are also temporary. These constraints are
documented in source so each can be removed independently and tested.

This device-specific package is a reference point, not the intended final
pmaports architecture. Once the remaining hardware paths are stable, the
OnePlus changes should move to the shared SM8150 kernel package and the normal
postmarketOS device package.
