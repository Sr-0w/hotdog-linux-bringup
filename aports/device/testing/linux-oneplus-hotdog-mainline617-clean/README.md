# OnePlus 7T Pro Clean SM8150 6.17 Baseline

This aport is the clean migration baseline away from the ClearStaff 6.16 r181
bring-up stack. The migration device package selects it; every revision still
passes the normal offline image and staged hardware gates before promotion.

## Base

- Upstream: `https://gitlab.com/sm8150-mainline/linux`
- Tag: `v6.17.0-sm8150`
- Tag object: `0f92d27107fd06add351756c9de56d824ac920d6`
- Exact commit: `379d8fe35c7ca685a650bd82fd023af0ea3f0de0`
- Base tree: `58281f438aa0de9debd9001d0921eb06a677e2dd`
- Reference pmaports revision: `linux-postmarketos-qcom-sm8150-6.17.0-r2`
  at pmaports commit `c7e574b4975ed244a10d368cc3d01454ca7c1cef`

The source archive URL is pinned to the commit rather than relying on the tag
name. The eighteen patches are exported from the local kernel branch
`bringup/hotdog-sm8150-clean-baseline` at commit
`d1584b678d01ed2797d26687c9d23e2793fca305`, tree
`07702ec78144a2b5b3bfbefc1e8111e42c774f3c`, and retain their commit
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
- SM8150 CAMSS with all four hotdog sensors, both focus actuators, dual-LED
  flash and the Hall-terminated popup mechanism;
- SLPI/FastRPC with the two SM8150 PDR domains and the complete Elliptic
  hostless audio/IIO proximity path;
- the upstream DWC3 request-giveback race fix needed when an active NCM gadget
  is reconfigured to add the ACM console;
- the pmaports LLVM prototype fix required by the shared configuration.

## Deliberately deferred

The kernel-side functional matrix is now restored. Radio userspace for
data/calls/SMS and the private Elliptic calibration remain in the device
packages;
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

The r4 package contains 829 modules, all with vermagic
`6.17.0-sm8150-hotdog-clean SMP preempt mod_unload aarch64`. This remains an
offline checkpoint until the staged phone boot confirms modem, QRTR, IPA,
Wi-Fi and audio enumeration.

## Complete migration package build

Revision r7 adds CAMSS, all four camera sensors, both actuators, flash, popup,
SLPI/FastRPC and Elliptic proximity. It also keeps sensors-PD FastRPC messages
in the remote heap and prevents generic power-domain pinctrl from claiming the
popup GPIO state. The strict build and complete validator passed on 2026-08-26.

| Artifact | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline617-clean-6.17.0-r7.apk` | 23,003,641 | `41f173a19b5cbe0202e7e0848c41a730d99c2a772c50ecb777da595356535abf` |
| packaged `boot/vmlinuz` | 31,492,608 | `e0dd783787bce562c87e87d9339307747bcde0b37ca00940d41c24ee3e86dbb0` |
| packaged Hotdog DTB | 164,102 | `9d31fa35ecd38dfd560209e6fb7d93f32dbc71eadac2b349ed594b07a32b3b12` |
| packaged `qcom-camss.ko` | - | `07e437a6c6756ae32f41860f9119dbcfc2ec36c245387ebe181404b7fa37a339` |
| packaged `hotdog-popup-motor.ko` | - | `408a6d134d98da8efdbe241f9c6d0160df4ce52bcdbba1bc42c8d3a381159a19` |
| packaged `fastrpc.ko` | - | `a21f85d84452b69f0ddee59ff9e9d7e98db8b7d5b84a58cc5ee2b3f85e18deae` |
| packaged `qcom_pd_mapper.ko` | - | `2eecc4aeb4ca37a94605bd56d8c9032597f077e761c62d00dcca93a188950eab` |
| packaged `q6elliptic.ko` | - | `1a49b33e8123151a207fb8141e8af5a3b25846e1684fee61bfd61b0fd7c17c40` |

The r7 package contains 840 modules with the same unique 6.17 vermagic. It is
the first package containing the complete migrated kernel feature matrix; its
camera, SLPI and proximity additions still require the staged hardware gate.

## Camera clock correction and complete electronic gate

Revision r8 enables the SM8150 camera clock controller that the r7 config had
accidentally omitted. The validator now requires both
`CONFIG_SM_CAMCC_8150=m` and the packaged `camcc-sm8150.ko`. No kernel source
patch changed between r7 and r8.

| Artifact | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline617-clean-6.17.0-r8.apk` | 23,013,453 | `f4894e2512a4b8469f00579c68582bc2f2f62ca04fac7c38003c84f3950d7629` |
| packaged `boot/vmlinuz` | 31,492,608 | `ad1bd2af47dc14f9bdecf282e9d8887fcb5605568d58f7b65c0d9df5bf6670ae` |
| packaged Hotdog DTB | 164,102 | `9d31fa35ecd38dfd560209e6fb7d93f32dbc71eadac2b349ed594b07a32b3b12` |
| packaged `camcc-sm8150.ko` | - | `1862d62bef4afe92defca7eba18c02481f3e483640dec47442ccc2d7a1ae90f4` |

The r8 package contains 841 modules with the same unique 6.17 vermagic. On
hardware it booted directly in 21 seconds. CAMCC, both CCI controllers and
CAMSS bound; `/dev/media0`, eight video nodes and twenty subdevices appeared,
with all four sensors and both actuators loaded. SLPI, modem and ADSP remained
running and Elliptic proximity remained enumerated. This is the complete
electronic kernel gate. A 30-sample, 300-second monitor retained the same boot,
media topology, three running remote processors and QRTR service 400 at every
sample. Physical camera, popup and broader interaction tests remain
deliberately deferred until the final test pass.

## DWC3 teardown race correction

Revision r9 backports the upstream fix for concurrent DWC3 request giveback.
The full r8/r36 image reached the real rootfs after its nested GPT was expanded
to the 232 GB physical userdata partition, then reproduced a NULL pointer fault
while the OpenRC ACM service unbound the active initramfs NCM gadget. The kernel
logged `request ... was not queued to ep3in` immediately before the fault. The
upstream fix records the queued state for EP0 and prevents a second giveback of
an already completed request.

| Artifact | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline617-clean-6.17.0-r9.apk` | 23,013,574 | `f14e903f0b70e383d60b77c944566e224088b0a5000c0ccef43911a27dde68f1` |
| packaged `boot/vmlinuz` | 31,492,608 | `43f119f358955b2529041f338ddca22bd8e8250cfdf9b2545a1c28318f21418a` |
| packaged Hotdog DTB | 164,102 | `9d31fa35ecd38dfd560209e6fb7d93f32dbc71eadac2b349ed594b07a32b3b12` |

The strict r9 package build passed with the same 841-module inventory. Hardware
validation is pending; this package is not yet the selected full-image
candidate.
