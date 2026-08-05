# Mainline 6.16 clean public-image build

## Purpose

This record closes the host-side reproducibility gate between the validated
`r22` hardware image and a normal postmarketOS image assembled only from the
published package directories. It does not claim that the newly generated
root filesystem or its unwrapped boot image has been flashed to hardware.

## Clean input tree

The build used a detached pmaports worktree at commit
`918a1f4e4dd1ebcf0e4df226dbadc210a857fe9c`. Only these three package
directories were overlaid from this repository:

- `device-oneplus-hotdog`
- `firmware-oneplus-hotdog`
- `linux-oneplus-hotdog-mainline616`

The selected device was `oneplus-hotdog`, the kernel choice was `mainline`,
the UI was Plasma Mobile with UI extras, and the service manager was OpenRC.
All three local packages completed strict pmbootstrap builds.

## Kernel package result

The clean worktree produced
`linux-oneplus-hotdog-mainline616-6.16.0-r22.apk`:

| Artifact | Size | SHA256 |
|---|---:|---|
| Clean-worktree APK | 25,537,634 bytes | `3fb965bd03b8251bec148d2d2129e369790e561347ac439f929c224ccd8a2ec3` |
| Kernel `Image` | 27,572,232 bytes | `ef0f2784aed963d54ca1051b9251fea845fe190d392b3894a4667c34bf62378b` |
| Hotdog DTB | 141,026 bytes | `984d54b14ff0acaf47619e78451800db23eb3edaf98938290f5bbfbcc327b5ca` |

The DTB is byte-identical to the hardware-accepted package. The new kernel
and the accepted kernel differ in exactly 20 consecutive bytes: the GNU build
ID embedded at offset `0x165d260`. Every other byte is identical. The build ID
was calculated from the unstripped link output and therefore changes when the
isolated build directory changes, even though the installed `Image` payload
does not otherwise change. This is a cross-build-directory reproducibility
detail, not a source or executable-code delta.

## Plasma Mobile image

The normal pmbootstrap install path generated an Android sparse disk image
containing a 4096-byte-sector GPT, `pmOS_boot`, and `pmOS_root`:

| Artifact | Result |
|---|---|
| Sparse image size | 3,861,847,276 bytes |
| Expanded image size | 14,002,683,904 bytes |
| Sparse image SHA256 | `919463c947fcb709461a9b3475803bede3ea8c0aa8e66c5da836fef0ca4e3d43` |
| Boot filesystem UUID | `e409622e-17bb-484a-a813-7cb4b01fb56e` |
| Root filesystem UUID | `0531b306-49b7-48ff-ac31-d5773e12f7b1` |
| Installed packages | 1,523 |

The GPT starts `pmOS_boot` at sector 2048 with 122,880 sectors and
`pmOS_root` at sector 124,928 with 3,293,440 sectors. Read-only `e2fsck`
passes completed for both filesystems without an error.

The generated header-v2 Android image has the validated load addresses and
contains the matching filesystem UUIDs:

| Component | SHA256 |
|---|---|
| Raw `boot.img` | `1dbff2fbe84db6cf9b943b2caf244cf8eca3824b14df54efbbb0fe545e0aa817` |
| Kernel | `ef0f2784aed963d54ca1051b9251fea845fe190d392b3894a4667c34bf62378b` |
| Initramfs | `1bec6e9709bfd75fc5b39ae13473e129569b8590e2e9e1b7fb4d943a972a6f8d` |
| DTB | `984d54b14ff0acaf47619e78451800db23eb3edaf98938290f5bbfbcc327b5ca` |

The root filesystem includes Plasma Mobile, Discover with its Flatpak
backend, Angelfish, Dolphin, Konsole and QMLKonsole, KClock, Kalk, Koko,
KWeather, Megapixels, Merkuro, Okular Mobile, Spacebar, Plasma Dialer, and the
UI-extra applications Alligator, AudioTube, Elisa, Itinerary, KAlgebra,
Kasts, KDE Connect, and Keysmith. NetworkManager, SSH, Bluetooth, ModemManager,
RMTFS, PD mapper, and TQFTP services are enabled. Automatic PowerDevil suspend
is disabled in the AC, battery, and low-battery profiles.

## Packaging findings

With current edge repositories, UI extras select `tuned-ppd`, whose generic
`polkit` dependency can make apk choose `polkit-noelogind` before the device's
Plasma application subpackage requests `polkit-elogind`. Supplying
`polkit-elogind` as an explicit install package resolves the graph and matches
the variant already validated on hardware. This provider choice must be made
automatic or documented before submission.

The kernel already enables nftables and ships `nf_tables.ko` plus the expected
`nft_*` modules. pmbootstrap nevertheless prints an unsupported-firewall note
because its status check inspects the device kernel-selection subpackage
instead of the underlying kernel APKBUILD. This is a metadata/reporting issue,
not missing nftables code.

The standard raw `boot.img` has not yet been accepted on the OnePlus
bootloader. Hardware tests so far use a deterministic 96 MiB AVB envelope.
The new filesystem must not replace the current working development system
until the raw-image/AVB installation contract and a recovery path are pinned.

## Hardware continuity

The already accepted source-package `r22` system remained booted while this
image was assembled. A physical 0 A.D. 0.28.0 session launched, accepted
input, and rendered gameplay smoothly. A post-session kernel scan contained
no UFS, ext4, Adreno, panic, oops, or Qualcomm-transition failure.
