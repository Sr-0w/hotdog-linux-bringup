# Hotdog Kernel Migration to SM8150 6.17

Last updated: 2026-08-26

## Immutable source oracle

The complete pre-migration kernel is preserved at commit
`211577f492d791f47b3235796e9f5b2458324330` and annotated tag
`kernel-clearstaff-403b56c-r181-checkpoint`. Its checkpoint directory records
the ClearStaff commit, all 153 applied patches in order, one stray unapplied
patch, package recipe, input and resolved configs, cumulative diff, expected
final source tree and reconstruction scripts.

The independent reconstruction starts from ClearStaff
`403b56c33e2ccdda25d90378970a5e5b928dee19` and produces exact tree
`24c948f9555dff9feb7fbc48e54684cb638fa3ff`.

## Target selection

The migration starts from SM8150 tag `v6.17.0-sm8150`, exact commit
`379d8fe35c7ca685a650bd82fd023af0ea3f0de0`, tree
`58281f438aa0de9debd9001d0921eb06a677e2dd`. This is the base currently used
by the official postmarketOS SM8150 kernel aport.

The repository branch `sm8150/6.17` is four commits ahead of the tag. Its delta
contains a Nabu lid workaround, the FTS LLVM fix, an IDTP9418 warning fix and a
Xiaomi Raphael DTS. Only the generic LLVM fix is required by the current
Hotdog build. Starting from the tag plus that isolated fix avoids adopting
unrelated device work while staying aligned with pmaports.

Newer vanilla releases were not selected for the first migration checkpoint.
Moving directly to 6.18/6.19 would combine board reconstruction with a larger
kernel transition and make hardware regressions harder to localize.

The image userspace now comes from a separate clean pmaports worktree based on
upstream commit `8d24be3f898eb8c717678ceb881972cc6b1c76f9`. The repository's
public aports are overlaid with `scripts/prepare-hotdog-pmaports-current.sh`.
This replaces the old 2024 fork that accidentally downgraded the initramfs in
the first full-image candidate.

## Reconstruction policy

The r181 patch stack is an oracle, not an input series. Every new change must
correspond to a currently validated behavior or a dependency needed to reach
it. Diagnostic framebuffer painting, direct-entry pstore markers, camera
experiments, superseded UFS dumps and other historical scaffolding stay in the
immutable checkpoint.

The current tree uses eighteen focused commits and changes 102 kernel files.
The first seven-commit offline foundation build produced:

| Artifact | SHA256 |
|---|---|
| `Image` | `dd99ebf24fef1343f43b693e4c228f3057759d4659eed5a0fef58aad769dd4ce` |
| Final Hotdog DTB | `0f30f299f7c1faaec7370ce735f921df917631495428d705e4bd434f99e7619a` |
| Host-resolved config | `6bc1071a7b58fb215ee8a446b58230b3e87a48d69f80637188aeb0989a584c2c` |
| `System.map` | `de9cb3fbf9c8a9bc753117a9f5eb1296f10bb392de36473aedaf317233bf31ad` |
| `s6sy761.ko` | `340db8b61f3a9f18091891b8a6117d33fc5c0b77445328015812cdaec47b9385` |

The Image is 31,492,608 bytes and carries the validated ABL fields
`text_offset=0x80000` and `image_size=0x1ad0000`. The build produced 828
modules. The final packaged config uses a distinct
`6.17.0-sm8150-hotdog-clean` release to prevent module mixing.

## Current scope

The first boot candidate included:

- direct ABL entry and inherited APSS watchdog handling;
- Hotdog DT identity and stock-derived memory reservations;
- UFS, Apps SMMU and the validated 32-bit DMA aperture;
- USB peripheral gadget support needed for ACM/NCM and SSH recovery;
- simple framebuffer plus the native Samsung DSC panel;
- Adreno 640 GPU/GMU;
- power/volume keys and S6SY761 touch.

The reconstructed tree now also contains the alert slider, charging policy,
Type-C role switching, reboot modes, AW8697 haptics, PN553 NFC, IPA 4.1,
hotdog MPSS/ADSP firmware paths, WCN3990 Wi-Fi and Bluetooth, WCD9340 audio,
both TFA9874 amplifiers, CAMSS and all four cameras, the Hall-bounded popup
mechanism, SLPI/FastRPC/PDR and the Elliptic proximity path. The source series
is complete for the currently validated kernel feature matrix; remaining work
is runtime integration, physical coverage and upstream cleanup.

## Foundation oracle decisions

| r181 source | Validated contract | 6.17 decision |
|---|---|---|
| `0002`-`0011` | ABL load offset/window and inherited APSS watchdog | Rewritten as a 29-line config-gated entry quirk. Framebuffer painting, pmsg records and hold loops were dropped. |
| `0012`, `0027`, `0028` | Native Samsung DSC panel, two slices per packet, stock 60/90 Hz modes | Panel sequence retained; host integration rewritten with explicit packet-slice validation. DSI error instrumentation was dropped. |
| `0014`, `0029` | UFS request lists must stay below 4 GiB; UFS uses Apps SMMU stream `0x300` | Stream is already present in 6.17 DT; only the focused Qualcomm variant DMA-mask hook was retained. |
| `0030` | Legacy hardirq completion experiment | Not ported. Hardware r20 reproduced the failure and ruled this change out; threaded IRQ handling remains from 6.17. |
| `0031`, `0032` | Missing stock-owned RAM caused real page-cache corruption and crashdump | Exact XBL/AOP, removed-region and CDSP gaps retained in the minimal DTS. |
| `0016`, `0046`, `0047`, relevant `0156` hunks | S6SY761 wiring, reset, bounded boot wait and sensing rearm after resume | Retained as one DTS contract and one focused driver commit. |
| `0017` | Adreno 640/GMU and Hotdog ZAP firmware | DT enable and firmware path retained; no GPU driver changes were needed. |
| `0018`, `0053` | Real PM8150 GPIO volume keys | Recreated in the minimal DTS; the misleading RESIN input is disabled. |
| `0048`, USB parts of `0156` | Gadget recovery over ACM/NCM and translated DWC3 stream `0x140` | The 6.17 SM8150 SoC/common DT and config already provide these contracts, so no duplicate patch was added. |
| Linux 6.18 DWC3 fix | Concurrent endpoint teardown must not give back an already completed request | Backported after the first full-image rootfs boot reproduced the upstream use-after-free while adding ACM to active NCM. |
| Experimental RAID6 evidence outside r181 | 6.17 direct boot can stall in `raid6_select_algo()` benchmark | `CONFIG_RAID6_PQ_BENCHMARK` is disabled in the new package config; RAID6 functionality remains enabled. |

UFS ICE is also already described by the 6.17 SoC DT and enabled by the shared
configuration. The older temporary `qcom,ice` deletion is not reproduced.

## Current gates

- Exact r181 reconstruction: PASS.
- Clean 6.17 source series build (`Image`, modules, Hotdog DTB): PASS.
- Direct header fields: PASS.
- Panel, S6SY761 and UFS targeted object builds: PASS.
- New panel and touch bindings: PASS under direct `dt-doc-validate`.
- Full DT schema: retains pre-existing SM8150 common-tree warnings for UFS,
  PMIC, APR and RPMh naming; new Hotdog-specific schema findings are addressed.
- Packaged foundation build: PASS through r3. The strict r4 radio/audio build
  is PASS. The strict r8 complete build is PASS with 841 modules and APK
  SHA256
  `f4894e2512a4b8469f00579c68582bc2f2f62ca04fac7c38003c84f3950d7629`.
- DWC3 teardown correction: r9 offline package build PASS with 841 modules and
  APK SHA256
  `f14e903f0b70e383d60b77c944566e224088b0a5000c0ccef43911a27dde68f1`;
  hardware validation is pending.
- Full package-shaped image assembly/offline image QA: PASS. The exact
  14096007168-byte full image has SHA256
  `55f893c9b5f9b7b03f5f668e64b25a8668f451d950e3e4a771d4207097528cb4`.
- Hardware boot: PASS for r2, r3, r6, r7, r8 and r10. The first r4 warm reboot
  anomaly remains recorded below, but r7 returned without intervention in 56
  seconds and r8 returned without intervention in 21 seconds.
- Complete electronic runtime gate: PASS on r8. CAMCC, both CCI controllers,
  CAMSS, four sensor drivers, both focus actuators, popup power domain,
  SLPI/FastRPC/PDR and Elliptic proximity all enumerate together.

- SSC sensors on the clean image: PASS after repair. The first global gate
  found `HasAccelerometer` and `HasAmbientLight` false while `HasProximity`
  stayed true. That split named the fault: proximity comes from the IIO
  Elliptic device and owes SEE nothing, the other two come from SSC.
  `hexagonrpcd` serves `/usr/share/qcom` to the sensor DSP and the directory
  was empty, so `iio-sensor-proxy` connected to the SSC service and released
  the client a hundred seconds later, unanswered. The sixty-five SEE
  descriptions were shipped by no package and had only survived because the
  rootfs was never recreated. `hotdog-sensor-config` now ships them and the
  sensors subpackage depends on it; verified from a clean state with the
  manual copy removed first.

The hardware-tested 6.16 package remains the default until all pending gates
above pass.

## First hardware boots

The first packaged candidate reached ABL but not Linux because the generated
DTB lacked symbols consumed by the stock DTBO. Preserving overlay symbols with
`DTC_FLAGS_sm8150-oneplus-hotdog := -@` made the filtered stock overlay apply
offline and fixed the boot. The r2 candidate then reached a writable rootfs,
SSH, OpenRC and Plasma on `6.17.0-sm8150-hotdog-clean`. The r3 candidate added
the missing QUP0 enable and bound `3-005a` to `aw8697-haptics`; alert slider,
touch, GPU, charger, Type-C, NFC and reboot-mode devices also remained present.

The apparent slow boot is not a storage or early-kernel regression. The r2
kernel log mounts the root filesystem at 4.282 seconds. It then attempts the
generic `qcom/sm8150/oneplus7/modem.mdt` path at 6.508 seconds and fails with
`-ENOENT`. Userspace consequently emits repeated QRTR node-zero errors and
performs its modem and UIM waits before continuing to networking and the SLPI
service gate. The r4 radio block replaces that generic path with the hotdog
firmware, restores IPA and the modem SMP2P contract, and is expected to remove
the modem portion of that delay. This expectation still requires a staged
hardware boot; no timeout has been shortened to conceal it.

Evidence for these boots is retained under
`logs/2026-08-26-sm8150-617-block1-r2/` and
`logs/2026-08-26-sm8150-617-block1-r3/`. Physical feature tests remain deferred
until the complete migrated feature set is present.

## Radio and audio hardware gate

The first r4 boot remained black with no framebuffer, USB gadget or SSH. After
about five minutes the operator pressed Volume Up and Power; that manual key
sequence exposed `05c6:9008` briefly and initiated the recovery/restart. The
9008 transition was therefore not spontaneous and must not be described as an
automatic crashdump recovery. No useful ramoops record survived that failed
boot.

The following r4 boot reached SSH on the same kernel and rootfs. Its kernel log
mounted the root filesystem at 4.629 seconds, initialized IPA at 5.354 seconds,
booted the hotdog ADSP firmware by 5.482 seconds and the hotdog modem firmware
by 7.479 seconds. WCN3990 completed firmware startup by 13.135 seconds and
associated as `wlan0` by 21.292 seconds. Runtime enumeration also showed
`rmnet_ipa0`, a complete modem QRTR service table, ADSP and modem both running,
and the `OnePlus 7T Pro` SM8150 sound card.

This is a partial hardware gate, not a stable-boot PASS. A further ordinary
reboot must complete without a manual key sequence before the radio/audio
block can be promoted. The first black boot remains an unresolved regression
until that repetition classifies it.

## Complete r8 electronic runtime gate

The complete r7 tree first proved the FastRPC sensors-PD correction: SLPI,
modem and ADSP remained running for all 30 samples of a 300-second monitor,
with QRTR service 400 present and no SLPI crash. Camera enumeration was still
blocked because the package config omitted `CONFIG_SM_CAMCC_8150`; the
`ad00000.clock-controller` platform device therefore had no driver and both
CCI controllers deferred.

Revision r8 changes only the package config and validation contract. It adds
`camcc-sm8150.ko`, producing 841 modules. Its AVB boot image has SHA256
`de20bf94620195958c54d7fe790d58754aef8650e68f4703d1916b92947aef54`.
The readback-verified image booted directly on slot B in 21 seconds with no
9008 or 900e transition. Runtime then showed:

- CAMCC, `ac4a000.cci`, `ac4b000.cci` and `acb3000.camss` bound;
- `/dev/media0`, eight `/dev/video*` nodes and twenty V4L2 subdevices;
- IMX586, IMX481, IMX471 and S5K3M5 loaded, plus both LC898217XC actuators;
- the popup power domain ready while explicitly leaving the motor off;
- SLPI, modem and ADSP running, QRTR service 400 present and
  `elliptic_proximity` exposed through IIO;
- no camera-related deferred device; only the unrelated gpio-keys entry
  remains in `devices_deferred`.

A second 30-sample, 300-second monitor retained the same r8 boot identity,
media topology, all three running remote processors and QRTR service 400 for
every sample.

The A/B metadata was also checked read-only after the earlier r4 anomaly. Slot
B is active, bootable and successful; slot A is also bootable and successful.
The failed first r4 warm boot was therefore not caused by slot B being marked
unbootable. It remains classified as a transient warm-reset or initialization
state until stronger evidence identifies the exact cause.

This is an electronic enumeration and stability gate. No camera stream,
autofocus movement, flash, popup movement or other physical interaction was
performed, in accordance with the decision to run physical parity tests only
after the complete migrated stack is present.

## Package-shaped full image

The migration branch now selects r8 from `device-oneplus-hotdog` r36. Kernel
subpackages pin the exact matching device package revision, preventing the APK
solver from silently mixing a newer kernel package with an older device
package. The device package also provides `/usr/sbin/sshd -> sshd.pam`, so the
OpenRC SSH service works in a fresh rootfs rather than relying on an old output
mutation.
Its deviceinfo targets `userdata` explicitly and rejects the obsolete `super`
rootfs target.

The final offline candidate is:

| Artifact | Size | SHA256 |
|---|---:|---|
| full nested-GPT image | 14,096,007,168 | `55f893c9b5f9b7b03f5f668e64b25a8668f451d950e3e4a771d4207097528cb4` |
| boot AVB | 100,663,296 | `e60b2df6e3dc8be69de8e4e1ca8d91036e4591a2b1207f0d37dc4627947a4ce7` |
| Image | 31,492,608 | `ad1bd2af47dc14f9bdecf282e9d8887fcb5605568d58f7b65c0d9df5bf6670ae` |
| initramfs | 9,126,121 | `b88c9a8db53f1f5fd11969a3e400e9515b476978a8dfe6d7e73cb7ad5a1755ac` |
| Hotdog DTB | 164,102 | `9d31fa35ecd38dfd560209e6fb7d93f32dbc71eadac2b349ed594b07a32b3b12` |

Independent GPT CRC checks, backup header placement, `e2fsck -fn` on both
filesystems, AVB verification, p1 payload equality, UUID/cmdline matching,
single module-tree inventory, exact r8/r36 package versions, SSH and OpenRC
service inventory all pass. The candidate is preserved under
`build/2026-08-26-sm8150-617-migration-r8-r36-full/` and is not a release.

The first full-image boot exposed one deployment-only mismatch. The generated
GPT described the 14,096,007,168-byte file, while Hotdog's physical userdata
partition is 232,382,812,160 bytes. The initramfs stayed alive with NCM/ping
but `kpartx` could not mount the short nested geometry. The pre-test backup
proves that the working layout extends p2 and its backup GPT to the physical
end. `scripts/prepare-hotdog-userdata-gpt.py` generated bounded patches for
that exact geometry. Recovery write/readback passed and the following debug
boot reported the full physical size plus both nested partitions through
`kpartx`.

Continuing that boot exposed a second, independent blocker at about 65 seconds:
the rootfs ACM service unbound the active NCM gadget and DWC3 logged a request
that was no longer queued to `ep3in`, immediately followed by a NULL pointer
fault at `0x178`. Kernel commit `d1584b678d01` backports the Linux 6.18 fix for
the concurrent request-giveback race. Its r9 package passes offline validation;
the next hardware image must combine r9 with the already validated physical
GPT patches.

The subsequent oracle comparison proved that r9 was necessary but not
sufficient. The working standalone r8 and failing full r8 use the same kernel
and DTB; their initramfs and rootfs USB ownership differ. The corrected r10/r37
composition uses current postmarketOS initramfs, creates NCM+ACM atomically
before the first UDC bind, leaves the rootfs service as a getty-only consumer,
and restores the r181 USB-current, V4L2-flash and framebuffer-font configs.

The r10/r37 full hardware boot passed 90 samples over 15 minutes with stable
ACM, NCM, ping and SSH. Device r38 then replaced the generic backgrounded
qbootctl oneshot with a synchronous, localmount-ordered service; a fresh reboot
returned with a changed boot ID, both gadget functions and the new service in
started state. The final r10/r38 full image is preserved under
`build/2026-08-26-sm8150-617-migration-r10-r38-current/` and is not a release.
