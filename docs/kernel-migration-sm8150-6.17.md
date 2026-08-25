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

## Reconstruction policy

The r181 patch stack is an oracle, not an input series. Every new change must
correspond to a currently validated behavior or a dependency needed to reach
it. Diagnostic framebuffer painting, direct-entry pstore markers, camera
experiments, superseded UFS dumps and other historical scaffolding stay in the
immutable checkpoint.

The current tree uses thirteen focused commits and changes 58 kernel files.
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

The next validated block adds the alert slider, charging policy, Type-C role
switching, reboot modes, AW8697 haptics and PN553 NFC. The current offline
block adds IPA 4.1, the hotdog MPSS/ADSP firmware paths, WCN3990 Wi-Fi and
Bluetooth, WCD9340 audio and both TFA9874 speaker amplifiers. Cameras, popup
motor and the SLPI/Elliptic path remain deferred.

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
  is also PASS, APK SHA256
  `958d2eb4ab469f8465df9a5e2389fe29b5bc411a45006241ed2529083f3cb438`.
- Full image assembly/offline image QA: pending.
- Hardware boot: PASS for the r2 foundation and r3 haptics tree; the current
  radio/audio commit has not been booted yet.

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
