# OxygenOS F.22 IN/EU comparison and the LineageOS vbmeta contract

Date: 2026-08-28

## Question

An HD1911 installation of the public pmOS image returned from the Qualcomm logo
to fastboot before Linux produced evidence. The reference HD1913 booted the same
boot, DTBO and rootfs. This audit asks whether OxygenOS regional images require a
separate pmOS release and which additional state LineageOS installs.

## Authoritative inputs

- HD1911-IN `HD1911_11_F.22`, project `19830`;
- HD1913-EU `HD1913_11_F.22`, project `19831`;
- LineageOS `android_device_oneplus_hotdog` commit
  `e0f3e9d17ec069ba7c9fd9d1be2dab08e0c03a48`;
- LineageOS `android_device_oneplus_sm8150-common` commit
  `59fce4a3b302e7282746e4807ed1a5520497f82a`.

Both complete OTA payloads were extracted. Every partition was compared by
name, expanded size and SHA-256. Every differing filesystem was then mounted
read-only and compared by path, metadata and regular-file content.

## Partition-level result

Twenty-nine of 41 partitions are byte-identical:

```text
LOGO abl aop bluetooth boot cmnlib cmnlib64 devcfg dsp dtbo hyp imagefv
keymaster modem multiimgoem my_carrier my_company my_engineering oem_stanvbk
opproduct qupfw recovery storsec tz uefisecapp vbmeta vendor xbl xbl_config
```

Twelve partitions differ:

```text
my_bigball my_heytap my_manifest my_preload my_product my_region my_stock
odm product system system_ext vbmeta_system
```

The complete boot chain is therefore regional-common: XBL, ABL, TrustZone,
boot, recovery, DTBO and top-level vbmeta are identical. Modem, DSP, Bluetooth
and the vendor filesystem are also identical.

`vbmeta_system` differs only because it authenticates the differing Android
logical partitions. Its fingerprints, salts, root digests and `system_ext`
size follow those regional files. pmOS neither flashes nor consumes this
regional Android vbmeta system image.

## Filesystem-level result

| Partition | IN files | EU files | Same files | Changed | EU-only | IN-only |
|---|---:|---:|---:|---:|---:|---:|
| `my_bigball` | 53 | 37 | 23 | 11 | 3 | 19 |
| `my_heytap` | 119 | 119 | 118 | 1 | 0 | 0 |
| `my_manifest` | 20 | 20 | 12 | 8 | 0 | 0 |
| `my_preload` | 5 | 5 | 4 | 1 | 0 | 0 |
| `my_product` | 254 | 254 | 244 | 9 | 1 | 1 |
| `my_region` | 171 | 213 | 120 | 32 | 61 | 19 |
| `my_stock` | 694 | 694 | 663 | 25 | 6 | 6 |
| `odm` | 1428 | 1425 | 1403 | 14 | 8 | 11 |
| `product` | 215 | 215 | 214 | 1 | 0 | 0 |
| `system` | 2681 | 2681 | 2680 | 1 | 0 | 0 |
| `system_ext` | 2790 | 2780 | 2760 | 17 | 3 | 13 |

The content differences are Android region policy rather than an alternate boot
implementation: IN applications and call recorder, EEA/GDPR packages, carrier
profiles, regional settings, project `19830` versus `19831` overlays, and the
matching ACDB, sensor, NFC and DSDS Android configuration.

## What LineageOS does

The official LineageOS device database lists Hotdog models HD1910, HD1911,
HD1913 and HD1917. The current Hotdog product itself declares model `HD1911`.
The common SM8150 BoardConfig includes `boot`, `dtbo` and `vbmeta` in the A/B OTA
set and enables AVB with both:

```make
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --set_hashtree_disabled_flag
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --set_verification_disabled_flag
```

Together these are top-level vbmeta flags `3`. LineageOS therefore never
installs its boot/DTBO pair while leaving a stock flags-0 vbmeta behind. The
first pmOS releases accidentally relied on the reference handset already having
this LineageOS state.

This is not a recent workaround. The initial SM8150 commonisation commit
`529ec479f075ae411c1f59cd4e98a5fb045beb3d` already combined the hashtree flag
with raw flag `2` in 2019. Commit
`bb377f02b8bab1ed6c6e2adb4beec7da1ce1d80a` only migrated that longstanding
contract to avbtool's named verification-disabled option in 2025.
The device-specific ancestor commit
`62660de6ab5e9d300d41bc7820b26a91a9e1c859` already described the intent as
"disable vbmeta verification" in June 2019.

Primary references:

- <https://github.com/LineageOS/lineage_wiki/blob/main/_data/devices/hotdog.yml>
- <https://github.com/LineageOS/android_device_oneplus_hotdog>
- <https://github.com/LineageOS/android_device_oneplus_sm8150-common/blob/lineage-23.2/BoardConfigCommon.mk>

## Regional release consequence

The official IN and EU top-level vbmeta inputs are byte-identical, size 8192,
SHA-256 `f3373554f5600f43eb3915f23a4436a168713b7ed0cc3e357e6b08b17b9f8967`.
Changing only the big-endian flags field at byte offset 120 from `0` to `3` and
padding to the 64 KiB physical partition produces one common image:

```text
e1d9ee620f4fac7939042396de966bea0b735bf11cea8ccc9b346f4d0fee0d50
```

The IN/EU stock boot and DTBO inputs are also byte-identical. Applying the same
pmOS kernel, initramfs, DTB and DTBO release contract therefore produces the
same release assets for both regions. A duplicated `HD1911-IN`/`HD1913-EU`
binary tree would contain no regional byte difference and would falsely imply
an HD1911 hardware validation that has not happened.

The next release instead carries one common verification-disabled vbmeta and
keeps HD1911 support explicitly unvalidated until the external handset boots
that complete atomic set.

The packaged common image was flashed to the reference slot B and read back
byte-for-byte. Linux 6.17, writable root and SSH returned, followed by a
919-second stable monitor with no fastboot or EDL transition.

## IN userspace control on the reference handset

The reference HD1913 was also converted to a complete HD1911-IN F.22 software
baseline on slot A. The reconstructed `super` contained all 15 IN dynamic
partitions; stock IN `boot_a`, `dtbo_a`, `vbmeta_a` and `vbmeta_system_a` were
installed, while the other 29 OTA partitions had already been proven
byte-identical between IN and EU. OxygenOS booted after its required userdata
wipe and reported region `IN` and product model `HD1911` from the Android
system image.

This did not turn the handset into an HD1911. Bootloader-provided properties
still identified the physical HD1913 project: project `19801`, hardware version
`14`, RF version `4` and the HD1913 DTBO selection. The control is therefore a
regional-software test, not an HD1911 hardware emulation.

The exact published Alpha 2 rootfs, boot, DTBO and verification-disabled vbmeta
were then installed on slot A over that IN baseline. Linux
`6.17.0-sm8150-hotdog-clean`, writable root and SSH returned in 81 seconds. Full
partition readback matched the published boot, DTBO and vbmeta sizes and
SHA-256 values byte-for-byte. This rules out the differing IN Android logical
partitions as the cause of the early bootloader return on the external HD1911.
It does not rule out a real HD1911 hardware, provisioning or bootloader-state
difference; validation on physical HD1911 hardware remains required.

A subsequent live metadata audit also proved that `vendor_dlkm`, the only
LineageOS payload partition absent from F.22, did not survive in physical
`super`. The 31-sample Alpha 2 monitor passed for 907 seconds with one boot ID.
See [the residual-state audit](2026-08-28-lineage-residual-state.md).
