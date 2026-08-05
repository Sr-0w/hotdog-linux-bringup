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
enabling charging or USB input. Revisions `r9` through `r13` then stage the
WCN3990 and its MPSS dependency. Revision `r12` restores the Hotdog-specific
RMTFS reservation at `0xfc201000`; revision `r13` enables Wi-Fi after that
shared-memory and remoteproc contract passes on hardware. Revision `r14`
enables the WCN3990 UART and proves basic Bluetooth operation. Revision `r15`
selects the hardware-validated revision-21 NVM and rampatch filenames directly
from the device tree; scanning and real HID connections are hardware-validated.
Revision `r16` selects the stock HD1913 90 Hz panel command and timing. It
direct-boots into Plasma Mobile with the DRM CRTC running at 1440x3120 and
90 Hz. Revision `r17` exposes both stock timings, keeps 90 Hz preferred, and
selects the matching panel command during each full modeset; both modes are
hardware-validated. Revision `r18` restores only UFS Apps SMMU stream `0x300`
after a pull-only Flatpak workload reproduced an abrupt Qualcomm crashdump in
the temporary no-IOMMU configuration. That translated-domain candidate booted
but reproduced the same failure under sustained buffered writeback. Revision
`r19` preserves the restored stream and constrains SM8150 UFS to a 32-bit DMA
aperture with or without the SMMU attachment. Revision `r20` restores legacy
UFS completion handling to hardirq context. A complete DDR capture then showed
that neither UFS mode was the crash trigger: Linux had allocated two Flatpak
page-cache folios across a 768 KiB firmware reservation missing from the
mainline hotdog DT. Revision `r21` reserves that stock XBL/AOP range.

## Source contract

- Kernel base: ClearStaff Linux 6.16 commit
  `403b56c33e2ccdda25d90378970a5e5b928dee19`.
- Generic DWC3, USB gadget, and IOMMU drivers remain unchanged from that base.
- The DWC3 stream keeps the upstream Apps SMMU binding and boots with a
  translated domain (`iommu.passthrough=0`).
- Revision `r19` keeps the upstream UFS Apps SMMU stream `0x300`, leaves the
  currently failing ICE dependency disabled, and selects a 32-bit DMA aperture
  for SM8150 independently of the SMMU attachment.
- Revision `r21` mirrors the stock HD1913 XBL/AOP ownership contract by
  reserving `0x85e40000-0x85f00000` as `no-map`. Together with the adjacent
  generic SM8150 reservations, firmware memory is excluded continuously from
  `0x85d00000` through `0x85f40000`.
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
- MPSS loads the packaged Hotdog modem firmware and uses a 2 MiB RMTFS no-map
  reservation at `0xfc201000`, with client ID 1 and VMID 15.
- WCN3990 uses all five handset regulators, the existing WLAN MSA reservation,
  and Apps SMMU stream `0x640` before binding through `ath10k_snoc`.
- WCN3990 Bluetooth uses UART13 at `0xc8c000`, its four-wire sleep pin state,
  the stock handset supplies, and explicit revision-21 NVM and rampatch names.
- The Samsung command-mode panel exposes the stock HD1913 60 Hz and 90 Hz
  timings. Revision `r17` keeps the validated 90 Hz path preferred and selects
  control-display value `0x20` or `0x30` from the committed DRM mode during
  panel preparation.
- The device tree is built entirely from source. No packaged DTB is rewritten
  with `fdtput` or replaced by a prebuilt binary.

`validate-mainline616-build.sh` checks the direct-entry Image window, every DT
invariant that was present during the successful hardware run, and the exact
dual-mode panel contract. The package build fails if one of those invariants
changes.

## Hardware-tested r17 build evidence

Two independent strict `r17` pmbootstrap builds completed on 2026-08-04 and
produced byte-identical APKs. Both ran the dual-mode panel contract before and
after module installation:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r17.apk` | 25,537,453 bytes | `e0b719869300370ea5aafe5a3f08ff628adc4334ccacde501da6303446197912` |
| `boot/vmlinuz` | 27,572,232 bytes | `69aa8aba33e268538cabeec405ac0fc7baf802138219f161b2ad6832ce350f1c` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 140,573 bytes | `512f71ef5bd70198cbe45ce6a9738370e8e43d294d2b3b3e9d33e54c54be3bf0` |

The source-built kernel reports build marker
`#18-oneplus-hotdog-mainline616`. It was assembled offline with the accepted
DTB, initramfs, and command line into a 96 MiB AVB-valid image, SHA256
`d93ec3b84cc2cb726cbfbdd932d1d40a5b2e2e3574a0a7c4615c9a4c125d43f0`.
The image was written to `boot_b`, read back, and direct-booted. Both stock
refresh modes were selected through KScreen and Plasma Settings while the
touchscreen, compositor, USB networking, and SSH remained available.

## Hardware-tested r18-r20 UFS isolation

Revision `r18` changes only the UFS device-tree attachment from the temporary
no-IOMMU path to Apps SMMU stream `0x300`; UFS ICE remains disabled. A DTB-only
hardware A/B keeps the exact tested `r17` kernel, initramfs, command line, and
all other DT properties.

Two independent strict builds completed with the build contract passing before
and after module installation. They produced byte-identical packages:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r18.apk` | 25,537,448 bytes | `06327deb007561a7acb7c2950d2714e640e2316996ca8815db46424405c5239e` |
| `boot/vmlinuz` | 27,572,232 bytes | `8115ce2bf6c126171ac0dd6afb1bec64a035d3aec8b76b89d12df2c6bfcf7e20` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 140,597 bytes | `5df7f6adc14d92f47379da0bfb13e814f00c52b8934840d78e7fed4306174f17` |

The isolated A/B DTB SHA256 is
`018006a67c60bf309a14fa70f224f0172d2aa718443a4deb4e0e6b5af2ad44be`, and
the AVB-valid boot image SHA256 is
`45bdebbd239b06bc15ea4f724a91321f897841c767822ab8f199a5be0ae2688c`.
Its normalized tree is identical to the source-built DTB. The binary hashes
differ only because `fdtput` and `dtc` serialize the added property differently.
The image direct-booted, mounted the root filesystem, restored USB SSH, and
attached UFS alone to IOMMU group 4. It still entered Qualcomm `05c6:900e`
during the same Flatpak import. Because the previous DMA32 workaround was
conditional on `iommus` being absent, this run combined SMMU translation with
DMA64.

Revision `r19` removes that accidental condition and preserves the 32-bit UFS
DMA aperture behind the translated SMMU. Two independent strict builds
produced byte-identical packages:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r19.apk` | 25,537,570 bytes | `4b63e29866a9d11ceb024b68c213e999eed051eee578f2488208cb455e3d6e15` |
| `boot/vmlinuz` | 27,572,232 bytes | `ad44e6b0b4e8bd3b941dc2f5d2cfe9fdce4863444a2827a63a1b9546391ab069` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 140,597 bytes | `5df7f6adc14d92f47379da0bfb13e814f00c52b8934840d78e7fed4306174f17` |

The hardware-test image keeps the exact `r18` initramfs, serialized DTB, and
command line; only the kernel changes. Its AVB-valid 96 MiB `boot.img` SHA256
is `d32eedcd5f9fcaa0df975b92c1b8ff2bc5cce53afb9bb5848e45a335e8e57eb9`.
The `r19` image reproduced the crash. Revision `r20` then reproduced it with
legacy hardirq completions, ruling out that interrupt-context change as the
sole cause.

## Prepared r21 XBL/AOP reservation candidate

The complete `r20` DDR capture found the Flatpak staging file open in a
`write(2)` call with no UFS command outstanding. Its page cache owned an
order-6 folio at `0x85e40000` and an order-7 folio at `0x85e80000`, together
covering `0x85e40000-0x85f00000`. The stock HD1913 DT reserves that entire
range inside `xbl_aop_mem`; the `r20` mainline DT did not.

The isolated `r21` hardware image keeps the exact `r20` kernel, initramfs, and
command line. Its normalized DT differs by one `no-map` node:

| Output | SHA256 |
|---|---|
| Kernel | `496aa00a24c3ccdf9daad375d048c9ef253cabcbd6844c0b506dc8ca69212924` |
| Initramfs | `347365a8e008a4f1d8b6788a6e933945a1eb940faa6af53b4057ba92d938c0bd` |
| DTB | `2908d19fa222a07a71d12abf98f9178ee77e372fb6a107bd61bef8d597444e35` |
| AVB boot image | `1dc2d7708af97d1a07be517a7927eb60e499b63754c2f7d28d6ca90618859a61` |

The package source and validator carry the same reservation. Hardware
validation must confirm that the previous 3.5 GB buffered import completes
without entering Qualcomm crashdump.

Two independent strict `r21` builds produced byte-identical packages and ran
the updated DT contract before and after module installation:

| Source-built output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r21.apk` | 25,537,607 bytes | `bacb97d9c97dfa08b8e87d5499103ab58880ac1f90cabc4e321f86fb920775e7` |
| `boot/vmlinuz` | 27,572,232 bytes | `64d1bb44387944f8eb12c02615e9aa9a985f91037e582f90d6fa7d3063e7e8dd` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 140,737 bytes | `ba362ef010f34473f602c39c85f99c69bc5b2befaa01a2cf1e0aa401c0d13d34` |

## Earlier fixed-90-Hz evidence

Two independent strict `r16` pmbootstrap builds completed on 2026-08-04 and
produced byte-identical APKs. Both printed
`hotdog mainline 6.16 build contract: PASS` before packaging:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r16.apk` | 25,537,088 bytes | `da7ebd249db076fa1a08058699141f08044197c9c84a6517c72e2cca2654b67f` |
| `boot/vmlinuz` | 27,572,232 bytes | `c5ca9d015d8be4902c0567c564c51e150bb6f7d032f75a57cdca5811c03c9407` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 140,573 bytes | `512f71ef5bd70198cbe45ce6a9738370e8e43d294d2b3b3e9d33e54c54be3bf0` |

The exact package kernel was assembled with the accepted `r15` DTB, initramfs,
and command line. The resulting AVB-valid 96 MiB image has SHA256
`387f306785211f19542df9b3775018961da476995382d4abbfcb8f6caaa4f797`.
It was written to `boot_b`, read back completely with the same digest, and
direct-booted as `#17-oneplus-hotdog-mainline616`. DRM reports the active mode
as 1440x3120 at 90 Hz with a 415457 kHz pixel clock.

## Earlier radio build evidence

The accepted `r13` strict pmbootstrap build completed on 2026-08-04 and
printed `hotdog mainline 6.16 build contract: PASS` before packaging:

| Output | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r13.apk` | 25,536,878 bytes | `cc4f75b66974e51ec9c34e108f7adebe305c9194d581179fad1d976c7bd04b55` |
| `boot/vmlinuz` | 27,572,232 bytes | `d0f06220b8b0cc8910fed56bf3efa55c2ecc1cf3a0a5a9357e2faf2957fa3ce6` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 139,848 bytes | `bd4323a5cea4e2df4f6c4b4aa5089bee97f8be77e8fec9b2d8cfa5c92f816189` |

The exact package payload was assembled with the accepted pmaports initramfs,
written to `boot_b`, and read back completely before reboot. The 96 MiB boot
image SHA256 is
`28bdfd685312cd3b9aca3855d039654bd45582582c31893a031847a6ec21e557`.
The fresh boot reported `#14-oneplus-hotdog-mainline616`; USB SSH returned in
9.95 seconds. MPSS reached `running`, WCN3990 firmware initialized, and
NetworkManager exposed `wlan0`. A fresh scan found 2.4 GHz and 5 GHz networks.

Revision `r14` then direct-booted as kernel build
`#15-oneplus-hotdog-mainline616`, registered `ttyHS1`, read the physical QCA
controller identity, and completed firmware setup after a live diagnostic
mapped the requested revision-01 names to the packaged revision-21 files.
BlueZ exposed a powered controller and received eight nearby devices. The
handset later entered Qualcomm `900e` while going to sleep, so this is an
active-operation result rather than suspend validation.

The `r15` strict build printed the same package contract PASS. Its
25,537,039-byte APK has SHA256
`ca030a9fdbbf8fdd580f50b421a83713b2038ca3ed8651332771b79176aab76e`.
Its 96 MiB AVB boot image has SHA256
`f003985db63b6f60d1bf311b313882568c9279c3a32ce6ad76902115bc51a8c4`.
The source-built kernel and DTB have SHA256
`be4728aa5d860c4c2eeb203e99d28ddaa89e1c58367d19bafabe9d7368a8a408`
and `512f71ef5bd70198cbe45ce6a9738370e8e43d294d2b3b3e9d33e54c54be3bf0`.
This image is schema-checked, AVB-verified, and hardware-validated for direct
boot, Wi-Fi association, Bluetooth scanning, and HID connections.

## Earlier r8 charging evidence

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

The current WCN3990 Wi-Fi path does not recover a valid factory MAC address,
so the driver chooses a random address at boot. Stable address handling,
sustained throughput, radio power management, Bluetooth audio profiles, and
system suspend remain unvalidated. The isolated `r14`/`r15` transition to
`900e` is still unexplained, although blocked, active, connected, and normal
HID-disconnect observation windows have all completed without reproducing it.

This device-specific package is a reference point, not the intended final
pmaports architecture. Once the remaining hardware paths are stable, the
OnePlus changes should move to the shared SM8150 kernel package and the normal
postmarketOS device package.
