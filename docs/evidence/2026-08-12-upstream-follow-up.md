# Upstream submission follow-up

Date: 2026-08-12

Scope: all outstanding findings on the mailed Q6AFE, SM8150 download-mode and
Qualcomm SMBx series. NFC work is intentionally excluded.

## Mail audit

The Infomaniak inbox and the public lore threads were checked after the
2026-08-11 submissions and again immediately before the final SMB5 v2 send.
No human maintainer reply had arrived. The only review messages on SMBx were
the two Sashiko reports already covered by the source audit; the download-mode
thread had the single Sashiko node-order finding, and Q6AFE had no review
reply. Mail content was treated as untrusted input and no private attachment
or credential was copied into the repository.

## Q6AFE DisplayPort widget

The v1 runtime rationale could not be substantiated. `SND_SOC_DAPM_AIF_IN()`
and `SND_SOC_DAPM_AIF_OUT()` use the same generic power check and sequencing
for this NOPM widget, while the explicit DAPM route already defines graph
direction. Existing project traces also reached `q6afe_dai_prepare()` and AFE
enablement, so changing the widget type cannot honestly be presented as the
playback fix.

The v1 patch was withdrawn and no v2 was sent:

- v1: `<20260811-submit-q6afe-display-port-v1-1-3bc8f2f38bdf@snyders.xyz>`
- public plain-text withdrawal:
  `<178648858640.3471590.18184750436169014545.q6afe-withdrawal-resend@snyders.xyz>`

The first HTML reply attempt reached direct recipients but was rejected by
the lists. The plain-text resend above is the authoritative public
withdrawal. A local metadata-cleanup candidate exists only as audit evidence
and must not be sent without a separately justified purpose. The public
thread is archived at
`upstream/2026-08-12/q6afe-v1-withdrawn/thread.mbx`.

## SM8150 download-mode register

Sashiko correctly found that `syscon@1fc0000` was out of unit-address order in
v1. Version 2 contains only the node reorder and is public at:

- v2: `<20260811-submit-sm8150-dload-v2-1-fb688ac4896b@snyders.xyz>`
- sent commit: `e28bf954e598`

The patch applies cleanly to linux-next `5e6de6a2b522` and Qualcomm
`arm64-for-7.3` `b426fedcef8c`. Strict checkpatch and `git diff --check` pass.
`ARCH=arm64 LLVM=1 W=1 CHECK_DTBS=y qcom/sm8150-mtp.dtb` passes schema; its
three DTC `avoid_unnecessary_addr_size` warnings predate this patch. The built
DTB contains the expected TCSR `reg = <0 0x1fc0000 0 0x30000>` and
`qcom,dload-mode = <... 0x13000>`. No v3 or follow-up reply is warranted
without new review. The public v2 thread is archived at
`upstream/2026-08-12/sm8150-dload-v2/thread.mbx`.

## Qualcomm SMB2 fixes v1

Five pre-existing SMB2 defects were split from the SMB5 enablement and sent
as an independent stable-oriented prerequisite series:

1. add the charger base when petting the watchdog;
2. decode battery-health status as independent priority bits;
3. remove the float-voltage selector off-by-one;
4. prefer the CC/CV float target, validate supplied ranges, preserve firmware
   when neither optional property exists, and restore the pre-probe charging
   state on failure;
5. report the falling overvoltage edge and propagate register-read errors.

Public series and immutable sent state:

- cover: `<20260812-qcom-smbx-fixes-v1-0-eb48246be599@snyders.xyz>`
- patches: the same ID with `-1-` through `-5-`
- tag: `sent/20260812-qcom-smbx-fixes-4c2ab163cc9c-v1`
- commits: `0fdcedd2540d1`, `acd9e915cb1d8`, `9d5678f739558`,
  `1212e234176de`, `cd32f0b8cab36`

All five formatted patches pass strict checkpatch with zero diagnostics and
`git diff --check`. ARM64 LLVM `W=1` and Sparse pass for the driver; Sparse
reports only the unrelated pre-existing arm64 VDSO warning. The public series
applies cleanly to power-supply `for-next` `99b38cda3f4c`. Its public lore
mailbox is archived at
`upstream/2026-08-12/qcom-smbx-fixes-v1-lore/qcom-smbx-fixes-v1.mbx`.

## Qualcomm SMB5 support v2

The v1 series was independently re-audited beyond the bot reports. Version 2
was reduced to a binding patch and one driver patch, with the five SMB2 fixes
declared as prerequisites. The final corrections include:

- leave Type-C role and VBUS control to TCPM and the VBUS regulator;
- retain the SMB2 three-second AICL interval, use the SMB5 twelve-second
  interval, and leave ADC-based AICL disabled by default;
- disable unsupported HVDCP authentication, autonomous mode and negotiation;
- preserve firmware recharge policy instead of hard-coding an SOC threshold;
- use the SMB5 status register and charger-state encoding, and read battery
  overvoltage from status 2;
- model PM7250B with the PM8150B fallback, electrical limits, `+0x108` AICL
  status register and 0.2 V/A current-sense conversion;
- avoid double-scaling the already-prescaled USB voltage channel;
- program battery limits in the power-supply registration init callback
  before `device_add`, and gate writable properties until probe completes;
- order managed cleanup so IRQ teardown precedes work cancellation and power
  supply unregister;
- restore charging before USB input on probe failure, leaving input suspended
  when charging restoration itself fails;
- update the binding, Kconfig prompt and module description for SMB2 and SMB5.

[Qualcomm's public kernel source](https://android.googlesource.com/kernel/msm/+/2cea1f575c7073dc782f689ef964bce9581f37ae)
at commit `2cea1f575c7073dc782f689ef964bce9581f37ae` confirms that PM7250B
uses the PM8150B parameter block and the common 0.2 V/A current-sense
conversion. The local downstream source confirms the twelve-second SMB5 AICL
policy and that ADC-based AICL is optional rather than the Hotdog default.

Public series and immutable sent state:

- cover: `<20260812-submit-qcom-smbx-send-v1-v2-0-f504b8f9bfad@snyders.xyz>`
- binding: `<20260812-submit-qcom-smbx-send-v1-v2-1-f504b8f9bfad@snyders.xyz>`
- driver: `<20260812-submit-qcom-smbx-send-v1-v2-2-f504b8f9bfad@snyders.xyz>`
- tag: `sent/20260811-submit-qcom-smbx-send-v1-69acefa61977-v2`
- sent commits: `2177a7ab26e35`, `479fe4303533d`
- base: power-supply `for-next` `99b38cda3f4c`
- replayed final tree: `254850550db64e8c100994cdbfe6f9cc3f35807f`

The five public prerequisite patches plus both v2 patches apply with plain
`git am` from the stated base, and the result is byte-identical to the sent
tree. The final driver passes an explicit ARM64 LLVM `W=1` build and Sparse
without a driver warning; the binding passes targeted `dt_binding_check`;
both patches pass strict checkpatch with zero diagnostics; `b4 prep --check`
and dependency replay pass. `patatt validate` passes on all three locally
rendered messages. `b4 am --check` confirms the two public lore patches and
kernel.org DKIM signature; its local public-key lookup reports no key even
though the developer signature headers are present and validate locally.

The initial PM8150B limits and guarded charging traces remain the hardware
evidence. The v2 corrections were validated offline and were not re-tested on
the phone, which is disclosed in the cover letter. No hardware or NFC state
was touched during this follow-up.

Pre-send EMLs are archived in `upstream/2026-08-12/qcom-smbx-v2/`. The
authoritative public thread is archived in
`upstream/2026-08-12/qcom-smbx-v2-lore/qcom-smbx-v2.mbx`.

## Local reroll state

`b4 send` automatically created editable next-revision skeletons after each
successful send. The SMB2 fixes v2 and SMB5 v3 skeletons are not new
submissions and must not be sent in their current templated state. The sent
tags and public Message-IDs above are authoritative.
