# Mainline 6.16 clean public-image build

## Purpose

This record closes the host-side reproducibility gate between the validated
`r22` hardware image and a normal postmarketOS image assembled only from the
published package directories. The expanded root filesystem has since been
written to the handset's unused `super` partition with complete SHA-256
readback verification. Its matching boot image has not yet been booted, so
this record does not claim a successful clean-image hardware boot.

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
| Expanded image SHA256 | `4eeac156cca4a2bbe5f70074901d5067c561a6cbdfae9d69574fdf5fa40d7f88` |
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
The clean rootfs is therefore paired with a deterministic AVB-wrapped boot
image for its first test. The working development image remains intact in
`userdata` as a separately addressable fallback.

## Verified hardware staging

The clean expanded image was staged from the running source-package `r22`
system with
[`stage-super-rootfs-from-pmos-ssh.sh`](../../scripts/stage-super-rootfs-from-pmos-ssh.sh).
The source root was backed by `userdata`; `super` was unused and had a physical
capacity of 15,032,385,536 bytes. Before opening the target for writing, the
tool required all of the following:

- the expected handset serial and hotdog project, platform, and brand tokens;
- the exact source boot ID and kernel release;
- a physical block device whose sysfs `PARTNAME` is `super`;
- enough target capacity for the 14,002,683,904-byte image;
- no mount, swap, holder, loop backing, or active-root relationship involving
  the target;
- an exact SHA-256 match before transfer, after staging, and immediately before
  block access.

The writer used direct I/O and then read exactly the image length back from
`super`. The final digest was
`4eeac156cca4a2bbe5f70074901d5067c561a6cbdfae9d69574fdf5fa40d7f88`,
identical to the host image. The phone remained on the same source boot, and a
post-operation kernel scan found no runtime UFS error, block I/O error, panic,
oops, watchdog reset, or Qualcomm crash transition. The staging data was
removed only after the full readback passed. No reboot was issued.

## Hardware continuity

The already accepted source-package `r22` system remained booted while this
image was assembled. A physical 0 A.D. 0.28.0 session launched, accepted
input, and rendered gameplay smoothly. A post-session kernel scan contained
no UFS, ext4, Adreno, panic, oops, or Qualcomm-transition failure. The later
verified `super` staging operation preserved that same healthy source boot.
