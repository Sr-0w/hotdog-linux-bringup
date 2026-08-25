# OnePlus 7T Pro Clean SM8150 6.17 Baseline

This experimental aport is the first clean migration checkpoint away from the
ClearStaff 6.16 r181 bring-up stack. It is intentionally separate from the
hardware-tested package and is not selected by the device package yet.

## Base

- Upstream: `https://gitlab.com/sm8150-mainline/linux`
- Tag: `v6.17.0-sm8150`
- Tag object: `0f92d27107fd06add351756c9de56d824ac920d6`
- Exact commit: `379d8fe35c7ca685a650bd82fd023af0ea3f0de0`
- Base tree: `58281f438aa0de9debd9001d0921eb06a677e2dd`
- Reference pmaports revision: `linux-postmarketos-qcom-sm8150-6.17.0-r2`
  at pmaports commit `c7e574b4975ed244a10d368cc3d01454ca7c1cef`

The source archive URL is pinned to the commit rather than relying on the tag
name. The seven patches are exported from the local kernel branch
`codex/hotdog-sm8150-clean-baseline` at commit
`c1b8aff58c2ba5dc428c51e57dfe669a36a189c6`, tree
`8ddc2f65bd5e097ee5c7f88a42e656573d504690`, and retain their commit
identities. The cumulative source delta is 17 files, 1,036 insertions and 37
deletions.

## Included foundation

- bounded direct-boot header and inherited watchdog contract, without old
  framebuffer or pstore instrumentation;
- a new minimal Hotdog DTS with the hardware-validated memory reservations;
- UFS with Apps SMMU stream `0x300` and the validated SM8150 32-bit DMA mask;
- USB peripheral support inherited from the current OnePlus SM8150 common DTS;
- native 1440x3120 DSC panel at 60 Hz and 90 Hz;
- Adreno 640 GPU and GMU with the Hotdog ZAP firmware path;
- power and volume keys;
- S6SY761 touch with reset and resume recovery;
- the pmaports LLVM prototype fix required by the shared configuration.

## Deliberately deferred

The first baseline does not yet port audio, modem/data/calls/SMS, Wi-Fi,
Bluetooth, cameras, popup motor, NFC, haptics, alert slider, SLPI sensors,
Elliptic proximity, charger policy, or reboot/recovery integration. Those
remain available in the immutable r181 checkpoint and will be restored only
after direct boot, storage, USB recovery, display, GPU and input are stable.

## Validation state

The source tree builds `Image`, all configured modules and
`sm8150-oneplus-hotdog.dtb` with LLVM. The aport validator checks the exact ABL
header fields, absence of historical entry instrumentation, required config,
DTB reservations/devices, built-in panel and touch module vermagic.

This is an offline baseline only. Do not replace the hardware-tested kernel or
publish a release from it until a packaged image has passed the normal offline
image gate and a supervised hardware boot.

## First strict package build

The isolated pmbootstrap build completed on 2026-08-25. Package readback
confirmed the distinct kernelrelease, 828 installed modules, matching module
vermagic, Hotdog DTB and the exact direct-boot header fields.

| Artifact | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline617-clean-6.17.0-r0.apk` | 22,934,952 | `229373be81468c6c124fa754998200638fabc87a295bb1d8212c09667430fcd9` |
| packaged `boot/vmlinuz` | 31,492,608 | `ac520482fb0b5d13005db60dd3ecc9ee0868c7dfc81aaf6a7f0c40da2a98c9a1` |
| packaged Hotdog DTB | 100,101 | `0f30f299f7c1faaec7370ce735f921df917631495428d705e4bd434f99e7619a` |
| packaged `s6sy761.ko` | - | `4dd2988cb68386746cb56e10e3f83a426c05e03159f1be3a161c6bbc1ca8cb5a` |

These hashes describe the offline package checkpoint, not a hardware-approved
boot image or release.
