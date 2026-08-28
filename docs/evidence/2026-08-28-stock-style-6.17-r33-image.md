# Fresh stock-style postmarketOS image on Linux 6.17 r33

Date: 2026-08-28

## Purpose

The clean 6.17 branch had previously been tested with laboratory root filesystems
that already contained user and SSH state. This build starts from a new
pmbootstrap work directory and the current public pmaports tree. It verifies
that the clean Hotdog packages can produce the same kind of complete Plasma
Mobile installation as an official postmarketOS image before `main` moves away
from the immutable 6.16 oracle.

This is not a release and is not yet a hardware support claim.

## Inputs

- repository branch: `bringup/hotdog-sm8150-clean-baseline`;
- pmaports base: `8d24be3f898eb8c717678ceb881972cc6b1c76f9`;
- pmaports integration after the optional pre-bind ACM patch:
  `0d395b9ed6768cd51c7a48749e05efd5e325ac26`;
- kernel package: `linux-oneplus-hotdog-mainline617-clean 6.17.0-r33`;
- device package: `device-oneplus-hotdog 3-r44`;
- UI: postmarketOS edge, OpenRC, Plasma Mobile with UI extras;
- default release-image account: `user` with the postmarketOS disposable
  password `147147`;
- host SSH key import: disabled;
- additional packages requested through pmbootstrap: none.

The proprietary OOS10 modem and SLPI inputs were supplied to the isolated build
directory and verified against their package checksums. They remain outside
Git. The development-only `device-oneplus-hotdog-bringup` subpackage was not
installed.

## Build result

The first install attempt exposed two clean-room integration defects before an
image was created:

1. local Hotdog packages had to be built explicitly in the new package
   repository instead of being inherited from an older work directory;
2. the device application metapackage forced a second Polkit implementation
   instead of following the provider selected for OpenRC.

Device revision r44 removes that redundant Polkit dependency. The resumed
build compiled the entire local dependency chain, including the kernel,
libqmi, ModemManager, libcamera, iio-sensor-proxy, hexagonrpcd, firmware and
radio services. The final rootfs contains the intended local revisions:

- `linux-oneplus-hotdog-mainline617-clean 6.17.0-r33`;
- `device-oneplus-hotdog 3-r44` and its normal functional subpackages;
- `libqmi 1.38.0_git20260414-r3`;
- `modemmanager`, `modemmanager-openrc` and `libmm-glib`
  `1.25.95_git20260709-r9`;
- `libcamera 99990.7.2-r12` and `libcamera-tools` at the same revision;
- `iio-sensor-proxy 9999-r9`;
- `hexagonrpcd 0.4.0-r13`;
- OOS10 modem firmware `1.0.11.1.7-r3` and SLPI firmware `2.2.00083-r1`.

Plasma Mobile, its full extras set, camera, dialer, Spacebar, Megapixels and
the normal OpenRC services are present. The image has no host SSH keys, no SSH
host key generated at build time, no private host identity string in the user
or SSH configuration, and no inherited Wi-Fi, Bluetooth or prior user files.
The small KWallet created for the new account is installation-generated state,
not data copied from the handset.

## Artifacts

| Artifact | Size | SHA256 |
|---|---:|---|
| nested GPT image | 14,223,933,440 | `6dc7601ef826795b9ec47ea6f830930de1cacbf9cd426adc8f4a919c1c85a847` |
| AVB boot image | 100,663,296 | `6f577dcb814da2fc0bd865c02031a8238de0736fb5e549ff98e50f8abde17e4b` |
| packaged kernel APK | - | `130da938def24f970c918bd276b134f67e190e10c8ab146e55fdb16b59fd3911` |
| packaged device APK | - | `12daff0803d488647d90f7cc64038b1e9455e2fb28b21f70925841580b030f4c` |
| `vmlinuz` | 31,558,144 | `13515fa27e37fc02757fcaeb18452b385286bd931eec08501fb2c1a5ea36e0d9` |
| initramfs | 9,968,364 | `7d99de5f25631e68098427d33b769244390d9ee00ca78ac879cbcb770080fa3b` |
| Hotdog DTB | 164,239 | `f9892962bb764f8b1ee92eb9d854ae75a79f3c5ac1a68b418b470bc75d4807b0` |

The GPT uses 4096-byte sectors. `pmOS_boot` occupies sectors 2048 through
124927 and `pmOS_root` sectors 124928 through 3472383. Independent
`e2fsck -fn` passes on both filesystems. The rootfs contains one module tree,
`6.17.0-sm8150-hotdog-clean`, with 842 modules.

`avbtool verify_image` validates the boot footer, vbmeta structure and boot
hash. `unpack_bootimg` returns payloads byte-identical to the files listed
above. The generated command line selects TER16x32 and the new boot/root UUIDs,
without a laboratory-rootfs reference.

## First hardware deployment attempt

The phone entered protocol-valid bootloader fastboot from the running r32
system on slot A. Preflight confirmed an unlocked bootloader, a successful and
bootable slot, a 96 MiB `boot_a` partition and a 232,382,812,160-byte
`userdata` partition. The running `boot_a` hash matched the retained r32
rollback image.

`fastboot -S 512M flash userdata` wrote the complete r33 image as eight bounded
sparse fragments. Every send and write returned `OKAY`; total time was 258.609
seconds. The subsequent `boot_a` command did not return a send/write status and
hit its 120-second host timeout. It is therefore not evidence that `boot_a` was
written.

After the large transfer, the device remained visible as `18d1:d00d` but no
longer answered `getvar`. A host-side USB unbind/rebind produced xHCI setup
timeouts and the device stopped enumerating. No new Qualcomm `900e` or `9008`
identity appeared. Testing stopped at this boundary: `userdata` is known to be
r33, while `boot_a` must be treated as unknown until fastboot is restored and
the r33 boot image is flashed again with an explicit `OKAY` result.

This is a transport interruption, not a failed r33 boot result; the phone was
never instructed to reboot after the incomplete boot command.

## Gate status

Offline image gate: **PASS**.

Hardware image gate: **BLOCKED before boot** by the wedged fastboot USB
transport.

Remaining gate before moving `main`: restore protocol-valid fastboot, flash the
r33 boot image with a positive acknowledgement, then confirm direct boot,
writable root, Plasma Mobile, NCM/ACM and SSH. Every unvalidated kernel
experiment remains on its separate topic branch.
