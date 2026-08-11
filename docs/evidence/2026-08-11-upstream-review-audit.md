# Upstream review finding audit

Date: 2026-08-11

Scope: automated Sashiko review of the submitted SM8150 download-mode patch
and Qualcomm SMB5 charger v1 series. No human maintainer reply had arrived at
the time of this audit.

## Result

The bot reported six unique findings. Five are valid and one is a false
positive. The valid findings have source-level corrections prepared locally;
no revised series has been mailed yet.

| Finding | Verdict | Disposition |
| --- | --- | --- |
| SM8150 TCSR node is out of unit-address order | Valid, low severity | Move `syscon@1fc0000` after `syscon@1f60000` |
| Watchdog bark handler omits the charger base | Valid, pre-existing | Add `chip->base` to the watchdog-pet write |
| SMB5 probe failures leave input and charging disabled | Valid | Save both initial bits and restore them through a managed probe-failure action |
| SMB5 watchdog offsets `0x651` and `0x653` target the wrong block | False positive | No register change; retain the downstream-verified offsets |
| Missing SMB2 battery voltage can produce an invalid selector | Valid, pre-existing | Validate the property against the hardware range before conversion |
| SMB2 health uses an exact switch on a multi-bit register | Valid, pre-existing | Test fault bits independently in priority order |

The watchdog-base finding appeared in two Sashiko replies but represents one
underlying defect.

## Register-offset proof

The SMB5 watchdog-offset report is incorrect. Qualcomm's downstream PM8150B
definitions use:

```text
MISC_BASE                         0x1600
BARK_BITE_WDOG_PET_REG            MISC_BASE + 0x43 = 0x1643
WD_CFG_REG                        MISC_BASE + 0x51 = 0x1651
SNARL_BARK_BITE_WD_CFG_REG        MISC_BASE + 0x53 = 0x1653
AICL_RERUN_TIME_CFG_REG           MISC_BASE + 0x61 = 0x1661
```

The mainline driver receives the charger peripheral base `0x1000` from the
device tree and stores offsets relative to that base. Consequently,
`chip->base + 0x651` and `chip->base + 0x653` resolve to the exact downstream
PM8150B addresses `0x1651` and `0x1653`. The downstream `qpnp-smb5.c` driver
also writes these registers during charger initialization.

The distinct watchdog-pet bug is real because its interrupt handler used the
relative value `0x643` without adding `chip->base`, unlike the initialization
path.

## Prepared patch state

The integrated audit branch is `submit/qcom-smbx-v2-audited` in the linux-next
worktree. It is based on linux-next 20260810 (`3d08ff75a47a`) and currently
contains:

1. `d9974f13b50d` - include the charger base when petting the watchdog;
2. `e9840ce2a75c` - test SMB2 health bits independently;
3. `d19aafbeb9fa` - validate the SMB2 float voltage and remove the selector
   off-by-one;
4. `a5e3d1adef00` - extend the charger binding for PM7250B and PM8150B;
5. `681943957ad4` - add SMB5 support, including probe-failure state restore;
6. `2a3ac109d174` - program the AICL rerun interval.

The corrected download-mode patch is `1e0484224a84` on
`submit/sm8150-dload`. The mailed v1 artifacts remain unchanged.

## Validation

- `scripts/checkpatch.pl --strict` reports zero errors, warnings, or checks
  for all six integrated charger commits.
- `qcom_smbx.o` builds for ARM64 with LLVM and `W=1`.
- Sparse `C=2` checks `qcom_smbx.c` without a diagnostic. The build emits one
  unrelated pre-existing warning from `arch/arm64/kernel/vdso/vgetrandom.c`.
- The targeted `qcom,pmi8998-charger.yaml` `dt_binding_check` passes.
- `qcom/sm8150-mtp.dtb` builds and passes `CHECK_DTBS=y` after the TCSR reorder.
- Existing PM8150B register reads and guarded charging traces remain the
  hardware evidence for the SMB5 limits and offsets.

The newly added failure rollback has not been exercised through deliberate
hardware fault injection. Its cleanup registration and all post-disable error
paths were audited statically, and the integrated driver passes the checks
above.

## Submission follow-up

Before mailing a revision:

1. decide whether the three pre-existing qcom_smbx fixes should lead the SMB5
   v2 series or be sent as a separate prerequisite series;
2. regenerate the b4 v2 branch from the audited commits;
3. explain the rejected watchdog-offset finding with the absolute-address
   calculation above;
4. include a concise v1-to-v2 changelog and rerun the recipient dry run;
5. send only after inspecting the final rendered messages.
