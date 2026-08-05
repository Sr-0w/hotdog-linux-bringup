# Mainline 6.16 clean public-image build

## Purpose

This record closes the reproducibility gate between the validated `r22`
hardware image and a normal postmarketOS image assembled only from the
published package directories. The expanded root filesystem was written to
the handset's unused `super` partition with complete SHA-256 readback
verification. Its matching deterministic AVB boot image was then written to
`boot_b`, read back, and direct-booted into the clean Plasma Mobile system.

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

The standard raw `boot.img` has not been tested without an AVB footer. The
accepted hardware artifact is its deterministic 96 MiB AVB envelope, SHA256
`9b58a17e90d783c2780af65e35bc5ae706811bdf830a1c49b6cef475e77b6f79`.
`avbtool verify_image` accepts both its footer and embedded hash descriptor.
The working development image remains intact in `userdata` as a separately
addressable fallback.

### Automatic AVB generation

Device package `3-r7` installs a hotdog-specific `boot-deploy` postprocess hook
and depends on `android-tools-avbtool`. The hook receives the normal header-v2
image after `mkbootimg`, derives its salt from the raw-image SHA256, appends a
hash footer for partition `boot` with algorithm `NONE`, and requires a final
size of exactly 100,663,296 bytes. It then verifies the partition name,
algorithm, salt, original image size, and AVB structure before returning the
image to `boot-deploy`.

A strict package build produced `device-oneplus-hotdog-3-r7.apk`. A subsequent
clean pmbootstrap install assembled 1,524 packages and invoked the hook in both
the initial and final UUID-aware `mkinitfs` passes. The final offline image has
these identities:

| Property | Result |
|---|---|
| `pmOS_boot` UUID | `b66e886a-cf8e-48e3-9066-193f6bc73179` |
| `pmOS_root` UUID | `4397ec91-e28e-4d19-ae00-008043fd0e73` |
| Raw image size | 37,203,968 bytes |
| Raw image SHA256 and AVB salt | `ce21ffee7a89ba6fbafc9f85be4aab60b746add3ff0f172bdd9988f061adf1ff` |
| Final AVB image size | 100,663,296 bytes |
| Final AVB image SHA256 | `2f90de75cdaa2041d63a143f02864d3e473b3877e04520edd9c93eedadf8766b` |
| AVB release string | `avbtool 1.4.0` |

`avbtool verify_image` accepts the result. Reconstructing the envelope from the
raw prefix with the image's target-side avbtool produced identical bytes, and
rerunning the complete final `mkinitfs` path produced the same AVB SHA256.
Determinism is therefore established for the resolved package set; the AVB
release string means byte identity across different avbtool versions is not
claimed. This `3-r7` image has not been written to hardware. It preserves the
same footer contract already accepted on the phone and removes the manual
wrapper from normal future builds.

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

## Clean-image first boot

The deterministic AVB image was written only to physical `PARTNAME=boot_b`.
Its complete 100,663,296-byte readback matched SHA256
`9b58a17e90d783c2780af65e35bc5ae706811bdf830a1c49b6cef475e77b6f79`.
A single normal reboot removed USB NCM and exposed the new NCM function again
about six seconds later. SSH then attested the clean installation:

| Property | Hardware result |
|---|---|
| Kernel | `Linux 6.16.0-sm8150 #23-oneplus-hotdog-mainline616` |
| `pmOS_boot` UUID | `e409622e-17bb-484a-a813-7cb4b01fb56e` |
| `pmOS_root` UUID | `0531b306-49b7-48ff-ac31-d5773e12f7b1` |
| Nested GPT backing | `/dev/loop0` backed by physical `super` |
| Root and boot mounts | `/dev/loop0p2` and `/dev/loop0p1` |
| Installed packages | 1,523 |
| Graphical session | `tinydm`, KWin Wayland, and Plasma Shell running |
| Native scanout | 1440x3120 AR30 KWin buffer at 90 Hz |

The clean system also exposed the Adreno render node, S6SY761 touchscreen,
Power and both volume-key inputs, a dual-band WCN3990 Wi-Fi scan, a powered
Bluetooth controller, running modem remoteproc, and battery/charger supplies.
NetworkManager, SSH, Bluetooth, nftables, elogind, and the no-suspend policy
were active. A first-boot kernel scan contained no runtime UFS error, block I/O
error, GPU fault, SMMU fault, DWC3 failure, panic, oops, or Qualcomm crash
transition. Sensor and telephony userspace services remain outside this image
acceptance result.

A 300-second persistent runtime observation then completed all 151 planned
samples without a USB transition. Every sample retained the UFS disk, root
loop, configured USB gadget, charger, and Bluetooth controller. UFS runtime
power management alternated normally between active and suspended states.

## Hardware continuity

The already accepted source-package `r22` system remained booted while this
image was assembled. A physical 0 A.D. 0.28.0 session launched, accepted
input, and rendered gameplay smoothly. A post-session kernel scan contained
no UFS, ext4, Adreno, panic, oops, or Qualcomm-transition failure. The later
verified `super` staging operation preserved that same healthy source boot.

After the clean public image direct-booted from `boot_b` and `super`, Discover
installed 0 A.D. on that clean installation as well. The game launches and
runs smooth interactive gameplay. This closes the continuity inference: the
publication-shaped rootfs itself now has direct application-level evidence for
Flatpak deployment, large UFS-backed content, accelerated graphics, input, and
runtime stability.
