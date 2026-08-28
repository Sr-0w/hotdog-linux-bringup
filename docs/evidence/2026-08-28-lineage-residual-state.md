# LineageOS residual-state audit after the OxygenOS control

Date: 2026-08-28

## Question

The reference HD1913 had previously run LineageOS. A complete OxygenOS 12 F.22
IN software baseline and the public Alpha 2 image both boot on it, while an
external physical HD1911 returns to the bootloader before Linux evidence. This
audit asks whether LineageOS writes a partition image that the OxygenOS payload
does not replace and that could explain the difference.

## Payload comparison

The LineageOS 22.2 Hotdog payload manifest contains 30 partitions:

```text
LOGO abl aop bluetooth boot cmnlib cmnlib64 devcfg dsp dtbo hyp imagefv
keymaster modem multiimgoem odm product qupfw recovery storsec system
system_ext tz uefisecapp vbmeta vbmeta_system vendor vendor_dlkm xbl
xbl_config
```

The official OxygenOS 12 F.22 payload contains 41 partitions. Twenty-nine are
common to both manifests. The only LineageOS-only image is:

```text
vendor_dlkm
```

OxygenOS adds its twelve regional and OnePlus partitions:

```text
my_bigball my_carrier my_company my_engineering my_heytap my_manifest
my_preload my_product my_region my_stock oem_stanvbk opproduct
```

This comparison uses payload manifests rather than filenames adjacent to an
OTA archive. It therefore includes the Qualcomm firmware partitions that the
LineageOS full OTA carries in addition to boot and Android logical partitions.

The relevant LineageOS build configuration independently lists the A/B images
and enables the firmware update path:

- <https://github.com/LineageOS/android_device_oneplus_hotdog/blob/lineage-22.2/BoardConfig.mk>
- <https://github.com/LineageOS/android_device_oneplus_sm8150-common/blob/lineage-22.2/BoardConfigCommon.mk>
- <https://github.com/LineageOS/lineage_wiki/blob/main/_data/devices/hotdog.yml>

## Direct check of the phone

The IN control did not update an existing Android dynamic-partition layout. It
rebuilt physical `super` from scratch with the 15 OxygenOS IN logical
partitions, empty slot-B entries and no `vendor_dlkm`, then flashed that image.

After Alpha 2 booted, the first MiB of the physical UFS `super` partition was
read through Linux without writing the phone. `lpdump` parsed the live primary
metadata directly:

- physical device: `/dev/sda15`;
- size: 15,032,385,536 bytes;
- metadata version: 10.2;
- metadata slots: 3;
- `vendor_dlkm` occurrences: 0.

The live metadata contains only `vendor`, `system`, `product`, `odm`,
`system_ext` and the ten OnePlus regional logical partitions, with populated
slot-A extents and empty slot-B entries. Therefore the one image unique to the
LineageOS payload did **not** survive the OxygenOS control.

## Installation-contract cross-check

The OxygenOS-IN-to-Alpha-2 run used the public installation operations:

1. verify the unlocked bootloader and target identity;
2. enter fastbootd;
3. flash the expanded rootfs to physical `userdata` with 128 MiB sparse
   transfer segments;
4. return to bootloader fastboot;
5. flash the matching vbmeta, DTBO and boot images;
6. activate the target slot and reboot.

No `fastboot -w`, `erase userdata`, filesystem format or additional wipe was
used. Slot A replaced slot B only for this controlled experiment. The earlier
stock-recovery wipe was required to boot OxygenOS after changing its EU Android
userspace to IN; it was not part of installing pmOS. Flashing the documented
pmOS `userdata` image subsequently replaced that partition in full.

Alpha 2 reached SSH in 81 seconds. Full `boot_a`, `dtbo_a` and `vbmeta_a`
readback matched the public release hashes. A 31-sample monitor then covered
907 seconds with the same boot ID, continuous ping and SSH, USB identity
`18d1:d001`, and no fastboot, 9008 or 900e transition.

## Conclusion

There is no remaining LineageOS-only partition image in the tested phone state.
LineageOS can also change non-image state while installing or booting, such as
A/B retry/success attributes, `misc`, encrypted `metadata` and userdata. It
does not flash device calibration or modem NV partitions through this OTA
payload. In this control, OxygenOS booted, userdata/metadata were reset by its
authorised wipe, and pmOS subsequently marked slot A active, bootable and
successful.

The remaining explanation for the external early return is therefore not a
surviving LineageOS image. Physical HD1911 hardware identity, provisioning,
bootloader behaviour or per-device A/B state remain candidates and require a
control on actual HD1911 hardware.
