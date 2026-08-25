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
name. The twelve patches are exported from the local kernel branch
`bringup/hotdog-sm8150-clean-baseline` at commit
`1c869546edb1127c15d28e68b21f1efb3b25ceba`, tree
`5c5776653e12bbf4aae4d557477f1c3637a61948`, and retain their commit
identities.

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
- alert slider, PM8150/IMEM bootloader and recovery modes;
- SMB5 charging policy, external fuel gauge and Type-C role switching;
- AW8697 haptics and PN553 NFC;
- IPA 4.1, the hotdog MPSS/ADSP firmware paths and QRTR radio foundation;
- WCN3990 Wi-Fi and Bluetooth wiring with modem-restart recovery;
- WCD9340 handset audio, DisplayPort audio and dual TFA9874 speakers;
- the pmaports LLVM prototype fix required by the shared configuration.

## Deliberately deferred

The next blocks still need cameras, popup motor, SLPI sensors and Elliptic
proximity. Radio userspace for data/calls/SMS remains in the device packages;
this kernel block restores the hardware and transport foundation it requires.
The remaining pieces stay available in the immutable r181 checkpoint and are
restored only in bounded, independently tested groups.

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

## Radio and audio package build

Revision r4 adds the hotdog modem/ADSP firmware contract, IPA 4.1, WCN3990 and
the complete handset audio topology. A strict isolated build completed on
2026-08-26. The strengthened validator checked the new config, DT nodes,
firmware paths and installed modules both before and after packaging.

| Artifact | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline617-clean-6.17.0-r4.apk` | 22,955,690 | `958d2eb4ab469f8465df9a5e2389fe29b5bc411a45006241ed2529083f3cb438` |
| packaged `boot/vmlinuz` | 31,492,608 | `3a5b107bee5cacdce84a834db86d7c00fa82c5b320bb51651a373ad1116f4466` |
| packaged Hotdog DTB | 149,236 | `577d6498505b8143f9c62f994a54a6a6cb2ed6a9c881944ed61a11c4a1a711b4` |
| packaged `ipa.ko` | - | `175d81875d0d17111c87177f9ef346f630a52a87295d203c127422a077a7412c` |
| packaged `qcom_q6v5_pas.ko` | - | `3524c42e1dafcfa4389610bac514e179a0a877c3b56e80cb815be59bd9965acb` |
| packaged `snd-soc-tfa9874.ko` | - | `b9b70c071504a07c082f603dca82c2e79e19239ace3ea031cbdd1d6bc8000d79` |

The package contains 829 modules, all with vermagic
`6.17.0-sm8150-hotdog-clean SMP preempt mod_unload aarch64`. This remains an
offline checkpoint until the staged phone boot confirms modem, QRTR, IPA,
Wi-Fi and audio enumeration.
