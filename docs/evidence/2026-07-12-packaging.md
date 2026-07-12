# Packaging evidence - 2026-07-12

## Scope

This record captures the checked-in hotdog package structure and the exact
`firmware-oneplus-hotdog` `20241212-r0` APK set revalidated on 2026-07-12. It
is packaging evidence only: it does not establish hardware support, direct-boot
success for a package-generated image, firmware redistribution approval, or
acceptance by postmarketOS.

The public package snapshots and their canonical relationship are described in
the [aports snapshot documentation](../../aports/README.md). The intended
submission boundary is maintained separately in the
[pmaports upstreaming plan](../pmaports-upstreaming.md).

## Device kernel split

The [device APKBUILD](../../aports/device/testing/device-oneplus-hotdog/APKBUILD)
exposes two kernel subpackages instead of making a kernel a dependency of the
base device package:

| Subpackage | Purpose | Runtime dependencies |
| --- | --- | --- |
| `device-oneplus-hotdog-kernel-downstream` | Boot-proven LineageOS 4.14 rescue bridge | `linux-oneplus-hotdog-lineage414` |
| `device-oneplus-hotdog-kernel-mainline` | Experimental Linux 6.17 K1-input reproduction | `linux-oneplus-hotdog-mainline617-k1`, `mesa-vulkan-freedreno` |

For a fresh pmbootstrap configuration, downstream is the initial selection:
the device APKBUILD lists it before mainline, and the local pmbootstrap kernel
selector falls back to the first parsed kernel when no saved valid selection
exists. An existing valid selection remains unchanged, and selecting
`mainline` explicitly installs the mainline subpackage instead.

The choices cannot be co-installed. Each subpackage has a negative dependency
on the other:

```text
device-oneplus-hotdog-kernel-downstream:
    !device-oneplus-hotdog-kernel-mainline

device-oneplus-hotdog-kernel-mainline:
    !device-oneplus-hotdog-kernel-downstream
```

pmbootstrap adds only `device-oneplus-hotdog-kernel-$kernel` for the selected
kernel type. The base device package therefore remains independent of either
kernel implementation.

## Initramfs module list

The former `device-oneplus-hotdog/modules-initfs` contained one entry, `msm`.
It has been removed because Qualcomm DRM is built into both kernels represented
by the split:

- [downstream configuration](../../aports/device/testing/linux-oneplus-hotdog-lineage414/config-oneplus-hotdog-lineage414.aarch64): `CONFIG_DRM_MSM=y`;
- [mainline K1 configuration](../../aports/device/testing/linux-oneplus-hotdog-mainline617-k1/config-oneplus-hotdog-mainline617-k1.aarch64): `CONFIG_DRM_MSM=y`.

A built-in driver has no `msm.ko` to preload, so retaining `msm` in
`modules-initfs` would request a loadable module that is not produced. This
removal proves only that the forced initramfs entry is unnecessary; it does not
claim that the DRM, DSI, panel, or userspace display path is functional.

## Firmware r0 evidence

The [firmware APKBUILD](../../aports/device/testing/firmware-oneplus-hotdog/APKBUILD)
is `pkgver=20241212`, `pkgrel=0`. Every package destination is below
`/usr/lib/firmware`; no payload is installed below the legacy
`/lib/firmware` path.

The strict offline build produced one empty parent package and seven payload
subpackages. The archive inspection found exactly 16 payload members, all
below `usr/lib/firmware/{ath10k,qca,qcom}` and none elsewhere.

| APK | Bytes | Payloads | SHA256 |
| --- | ---: | ---: | --- |
| `firmware-oneplus-hotdog-20241212-r0.apk` | 1,234 | 0 | `477d04d4134bfd268c903d6632f3a3a02a02a5bb577c5249964626970444c00c` |
| `firmware-oneplus-hotdog-adreno-20241212-r0.apk` | 44,944 | 3 | `ad9919ca2652d364c90ace25e213ffdb3ba893293b95577ecda11b791705ad58` |
| `firmware-oneplus-hotdog-adsp-20241212-r0.apk` | 8,174,723 | 1 | `f3f05210b27bd58843070958b913323eee71cd02369e597d9f28faa618831acc` |
| `firmware-oneplus-hotdog-bluetooth-20241212-r0.apk` | 229,374 | 6 | `734e51e248e495989b056ad37268346043547b5b07e49724372752a4b5934930` |
| `firmware-oneplus-hotdog-cdsp-20241212-r0.apk` | 1,361,569 | 1 | `b27dcaeb46c7e8cd53445e31f9b19586c39f06590e74fbfe0659057332dbcc8b` |
| `firmware-oneplus-hotdog-modem-20241212-r0.apk` | 38,155,053 | 1 | `7cc8f685d07cfe6fd2ef57eab80a1a772789b3b4742020ca72de1315c8a5dc15` |
| `firmware-oneplus-hotdog-venus-20241212-r0.apk` | 552,475 | 1 | `b3099ff1ceea1b0599ef801827ea550ae95f1bf1f442366745804cf77d297b80` |
| `firmware-oneplus-hotdog-wlan-20241212-r0.apk` | 2,004,268 | 3 | `8e104cac424b664cb116567622c2692e43c274552f9f6167c9fe58bccd1f2d8e` |

The source archive recorded by the APKBUILD has SHA512:

```text
e4db4f210d04588cf66a86f3b45d06c5afedc7eb41cbd69954d7a8140b7e0b39c34eff91368c02c687f65291b45696955a3be39794401193abd76f473640a98d
```

The APK hashes identify this exact signed build set. A rebuild with another
abuild key or build timestamp can have different full-archive hashes even when
its payload content and layout are equivalent.

## Upstream boundary

The current base device package does not install the following subpackages by
default, and none has an `install_if` rule:

- `device-oneplus-hotdog-nonfree-firmware`: development aggregation for the
  proprietary firmware and bring-up services;
- `device-oneplus-hotdog-bringup`: passwordless `doas` policy restricted to a
  dedicated development phone;
- `device-oneplus-hotdog-wireplumber`: unvalidated local Qualcomm audio policy.

These three subpackages remain development-only and are excluded from the
initial upstream submission scope. The separate firmware aport remains subject
to provenance, redistribution, ownership-conflict, and pmaports policy review;
the successful local build does not satisfy those legal and project-review
gates.

The downstream bridge and the forensic K1 package are also evidence and
bring-up inputs, not the final shared-kernel upstream architecture. Direct boot
of the normal package-generated image remains a prerequisite under the
[direct-boot criteria](../direct-boot.md).

## Reproduction

After preparing a canonical pmaports checkout and its public snapshots, verify
the source state from the repository root:

```sh
diff -qr \
  src/postmarketos/pmaports-sm8150/device/testing/firmware-oneplus-hotdog \
  aports/device/testing/firmware-oneplus-hotdog

test ! -e aports/device/testing/device-oneplus-hotdog/modules-initfs
grep '^CONFIG_DRM_MSM=y$' \
  aports/device/testing/linux-oneplus-hotdog-lineage414/config-oneplus-hotdog-lineage414.aarch64 \
  aports/device/testing/linux-oneplus-hotdog-mainline617-k1/config-oneplus-hotdog-mainline617-k1.aarch64

pmbootstrap apkbuild_parse device-oneplus-hotdog
```

Verify checksums, lint the APKBUILD in an Alpine or pmbootstrap environment
with `atools-go`, then force a strict rebuild. Offline mode requires the source
archive and Alpine packages to be present in the pmbootstrap caches already.

```sh
pmbootstrap -o checksum --verify firmware-oneplus-hotdog

CUSTOM_VALID_OPTIONS="pmb:cross-native pmb:kconfigcheck-nftables" \
  apkbuild-lint \
  src/postmarketos/pmaports-sm8150/device/testing/firmware-oneplus-hotdog/APKBUILD

pmbootstrap -o build --force firmware-oneplus-hotdog
```

Set `PKGDIR` to the generated `packages/edge/aarch64` directory and verify the
archive set and payload layout:

```sh
PKGDIR=/path/to/pmbootstrap-work/packages/edge/aarch64
mapfile -t apks < <(
  find "$PKGDIR" -maxdepth 1 -type f \
    -name 'firmware-oneplus-hotdog*-20241212-r0.apk' -print | sort
)
test "${#apks[@]}" -eq 8

members=$(mktemp)
trap 'rm -f "$members"' EXIT
for apk in "${apks[@]}"; do
  tar --ignore-zeros -tzf "$apk" 2>/dev/null
done > "$members"

awk '
  /^\.SIGN\./ || /^\.PKGINFO$/ || /\/$/ { next }
  /^usr\/lib\/firmware\// { payloads++; next }
  { print "unexpected payload: " $0 > "/dev/stderr"; bad=1 }
  END { exit (bad || payloads != 16) }
' "$members"

stat -c '%n %s bytes' "${apks[@]}"
sha256sum "${apks[@]}"
```
