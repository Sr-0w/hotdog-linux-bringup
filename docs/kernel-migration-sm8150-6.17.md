# Hotdog Kernel Migration to SM8150 6.17

Last updated: 2026-08-25

## Immutable source oracle

The complete pre-migration kernel is preserved at commit
`20099d91f97ced4943bd2ddc78a4cd00b20b1b94` and annotated tag
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

The initial tree uses seven focused commits and changes 12 kernel files before
the final binding/maintenance cleanup. Its first offline build produced:

| Artifact | SHA256 |
|---|---|
| `Image` | `dd99ebf24fef1343f43b693e4c228f3057759d4659eed5a0fef58aad769dd4ce` |
| Hotdog DTB before final schema cleanup | `424274ebaaaf6302bc840063a138c34f620bdf12d550a0457cf928072840d436` |
| Host-resolved config | `6bc1071a7b58fb215ee8a446b58230b3e87a48d69f80637188aeb0989a584c2c` |
| `System.map` | `de9cb3fbf9c8a9bc753117a9f5eb1296f10bb392de36473aedaf317233bf31ad` |
| `s6sy761.ko` | `340db8b61f3a9f18091891b8a6117d33fc5c0b77445328015812cdaec47b9385` |

The Image is 31,492,608 bytes and carries the validated ABL fields
`text_offset=0x80000` and `image_size=0x1ad0000`. The build produced 828
modules. The final packaged config uses a distinct
`6.17.0-sm8150-hotdog-clean` release to prevent module mixing.

## Foundation scope

The first boot candidate includes only:

- direct ABL entry and inherited APSS watchdog handling;
- Hotdog DT identity and stock-derived memory reservations;
- UFS, Apps SMMU and the validated 32-bit DMA aperture;
- USB peripheral gadget support needed for ACM/NCM and SSH recovery;
- simple framebuffer plus the native Samsung DSC panel;
- Adreno 640 GPU/GMU;
- power/volume keys and S6SY761 touch.

Subsystems beyond that list are intentionally deferred. A successful first
boot must not be interpreted as restoring the full r181 feature matrix.

## Current gates

- Exact r181 reconstruction: PASS.
- Clean 6.17 source series build (`Image`, modules, Hotdog DTB): PASS.
- Direct header fields: PASS.
- Panel, S6SY761 and UFS targeted object builds: PASS.
- New panel and touch bindings: PASS under direct `dt-doc-validate`.
- Full DT schema: retains pre-existing SM8150 common-tree warnings for UFS,
  PMIC, APR and RPMh naming; new Hotdog-specific schema findings are addressed.
- Packaged pmaports build: pending.
- Full image assembly/offline image QA: pending.
- Hardware boot: not run.

The hardware-tested 6.16 package remains the default until all pending gates
above pass.
