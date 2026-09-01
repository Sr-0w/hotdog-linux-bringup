# LineageOS boot-state investigation

Date opened: 2026-09-01

## Question

Why does postmarketOS/mainline fail after a stock OxygenOS state but boot after
LineageOS installation or its first boot on the OnePlus 7T Pro?

The experiment separates changes made by the LineageOS installer from changes
made by LineageOS userspace during its first boot. Every scenario starts from a
fresh stock EDL flash so that a previous Android or postmarketOS boot cannot
contaminate `misc`, `metadata`, A/B attributes, UEFI variables, modem NV, or
other persistent state.

## Device and package identity

- Device: OnePlus 7T Pro European `HD1913`, Qualcomm SM8150, codename `hotdog`.
- OnePlus project: `19801`.
- Firehose identity: `HwVersion=14`, `RfVersion=4`, `PrjVersion=5`.
- Live storage: UFS, 4096-byte sectors, six GPT-bearing LUNs (`0` through `5`).
- Stock package inspected: `HD01BA`, OxygenOS 10 Android 10, build
  `hotdog_14_E.19_200928`, project path `OXYGEN_EU/MSM_19801`.
- The original OPS archive passes its packaged MD5 check.
- The extracted stock `persist.img` matches this handset's known-good factory
  `persist`, but the flash plan still excludes `persist` entirely.

Do not publish the EDL serial, private partition images, or per-device identity
data. Never restore `persist`, modem NV, calibration, or identity partitions
from another handset.

## PRE0: state found on 2026-09-01

The handset was already in Qualcomm `05c6:9008` EDL mode, but it was not stock
and therefore could not be called A0. `param` identifies `HD1913_14_210603`, and
`persist` contains OxygenOS `13.W.25`/`13.W.24` history. This state is recorded
as `PRE0` (unknown prior boot history).

Local ignored capture:

```text
backups/lineage-boot-state/2026-09-01-prewrite-edl
```

Capture result:

- live GPT text and primary/backup GPT sectors for LUN 0 through LUN 5;
- 116 named partition images and 128 verified SHA256 entries;
- 39 identity, calibration, security, and modem-state partitions read twice;
- both independent critical reads match bit for bit;
- approximately 20 GiB retained outside Git;
- `userdata` alone excluded: it is an encrypted 221 GiB partition and is not
  part of the boot-state comparison;
- the key per-device partitions match the verified 2026-08-28 local dump.

No storage write, erase, reset, or slot change was performed while creating
PRE0. Loading the signed Firehose programmer changed target RAM only.

## Safety gates

No stock, LineageOS, or postmarketOS write may start unless all gates pass:

1. Exactly one `05c6:9008` device is visible and no `05c6:900e` device exists.
2. The signed Firehose loader and source package hashes are recorded.
3. Both reads of every critical partition have matching sizes and SHA256.
4. Primary and backup GPT sectors for all six LUNs are retained.
5. The effective stock rawprogram contains no `persist` label or
   `persist.img` filename.
6. The source OPS extraction remains unchanged.
7. The exact target state and intended next boot are written in the run log.

The stock XML patches rewrite GPT metadata. This is expected for a full stock
restore and is why raw GPT backup is a mandatory gate.

## Reproducible tools

Prepare a stock plan without phone access:

```bash
scripts/prepare-hotdog-stock-edl-plan.sh SOURCE_EXTRACT OUTPUT_PLAN
```

Capture a state in EDL:

```bash
scripts/capture-hotdog-edl-state.sh \
  --state A0 \
  --edl-ng /path/to/edl-ng \
  --loader /path/to/prog_firehose_ddr.elf
```

Compare states by SHA256, followed by byte offsets only for changed images:

```bash
scripts/compare-hotdog-edl-states.sh CAPTURE_A CAPTURE_B 64
```

Apply the packaged QFIL GPT expressions offline and validate both GPT copies:

```bash
scripts/patch-hotdog-stock-gpt.py SOURCE_PLAN LIVE_CAPTURE OUTPUT_DIR
```

When fastboot is available, collect slot and boot-control state before any
boot or flash:

```bash
scripts/collect-fastboot-reference.sh
```

## State protocol

| State | Start | Android action before capture | Required observations |
| --- | --- | --- | --- |
| A0 | Fresh stock EDL flash | Never boot OxygenOS | EDL capture, fastboot variables, postmarketOS/mainline boot result |
| A1 | Fresh stock EDL flash | Complete exactly one OxygenOS first boot | Same capture and boot test |
| B | Fresh stock EDL flash, then LineageOS install | Never boot LineageOS | Same capture and boot test |
| C | Fresh stock EDL flash, then LineageOS install | Complete exactly one LineageOS boot | Same capture and boot test |

Each row is an independent experiment. Return through a new stock EDL flash,
not by restoring a handful of partitions from a previous row. Preserve this
handset's unique partitions through every cycle.

Before each postmarketOS/mainline test, pin and record the SHA256 of `boot`,
`dtbo`, `vbmeta`, and any root/super payload. Capture `fastboot getvar all`, the
current slot, retry/success state when available, and the exact USB transition.
Do not allow a failed test to boot Android accidentally before its EDL capture.

## Interpretation

- A0 fails, A1 fails, B boots, C boots: the LineageOS installation is enough;
  bisect installer steps and flashed partitions.
- A0 fails, A1 fails, B fails, C boots: first-boot LineageOS initialization is
  the trigger; focus on partitions changed only between B and C.
- A0 boots, A1 fails: OxygenOS first boot creates the incompatible state.
- A0 and A1 both boot: the original failure was not reproduced; compare PRE0
  with A0 before changing the protocol.

For installer bisection, start with the exact `dtbo`, `vbmeta`, recovery/boot,
super/dynamic-partition, slot, and boot-control operations used by LineageOS.
For first-boot bisection, prioritize `misc`, `metadata`, `param`, `devinfo`,
`uefivarstore`, A/B GPT attributes, modem NV, and other images whose SHA256
changes from B to C. Byte-level inspection is restricted to that changed set.

## Stock flash and final A0

The effective stock XML was independently parsed before use:

- 57 source program entries;
- 56 entries after removing the sole `persist` program;
- 156 packaged GPT patch entries;
- 54 referenced payloads present and hash-verified;
- sector size and physical LUN range validated;
- no erase, reset, power, or unexpected XML operation.

`edl-ng` correctly rejected the first write because it does not perform the
OnePlus `demacia`/project authentication required by this loader. The rejected
target was `param`; its full readback still matched PRE0, proving no partial
write. The stock data flash then used bkerler/edl with project `19801`, which
performs that authentication in the same Firehose session as each program.

All 44 non-GPT program entries received an ACK. `persist` and the 12 GPT
program entries were excluded from that pass. A full post-write A0 capture
proved 43 payloads against their partition readbacks, including expansion and
comparison of Android sparse images. `userdata` was reset by an acknowledged
write but remains excluded from captures. The following per-device data stayed
bit-identical to PRE0:

- `persist`;
- `modemst1`, `modemst2`, `fsg`, and `fsc`;
- `mdm1m9kefs1`, `mdm1m9kefs2`, `mdm1m9kefs3`, and `mdm1m9kefsc`.

The preserved live GPT layout matched the package's LBAs, but its GUIDs and
A/B attributes did not match the packaged stock GPT. Keeping it would have
left a previous active-slot state inside the supposed A0. The package's local
GPT patch expressions were therefore applied offline using each live LUN size.
All primary/backup header and partition-array CRCs passed before writing.

Each stock backup GPT was written first, read back and compared byte-for-byte;
only then was its primary GPT written and verified. All six LUN pairs passed.
The physical boot LUN was set to LUN 1, matching `xbl_a`. The resulting stock
GPT has no active A/B slot detectable before first boot. PRE0 reported slot A,
so slot initialization is now a first-class candidate for the Lineage effect.

Final local ignored A0 capture:

```text
backups/lineage-boot-state/2026-09-01-175838-A0-final-stock-never-booted
```

This capture contains the verified stock partition data, direct post-write GPT
readbacks, a fresh live GPT inventory, and a complete SHA256 manifest. No
Android or LineageOS boot occurred between the stock flash and this capture.

## A1: first OxygenOS 10 boot

OxygenOS reached userspace once on slot A. Before returning to EDL, ADB
identified `HD1913`, Android 10 and `ro.boot.slot_suffix=_a`. The A0-to-A1
comparison found exactly 16 changed capture objects:

- primary and backup GPT images on LUN 0, LUN 1 and LUN 4;
- `config`, `metadata`, `op2`, `param`, and `persist`;
- `reserve1`, `reserve2`, and `reserve3`;
- `modemst1` and `modemst2`.

No partition name, type GUID, unique GUID, start LBA or end LBA changed. OOS
changed only A/B attributes in the three GPTs. Slot-A entries gained these
attribute bytes at GPT byte offset 6:

- `0x04`: active;
- `0x44`: active and boot-successful;
- `boot_a=0x7f`: active, successful, priority/retry fields initialized.

Fastboot confirmed the resulting state:

```text
current-slot: a
slot-successful:a: yes
slot-unbootable:a: no
slot-retry-count:a: 7
slot-successful:b: no
slot-unbootable:b: no
slot-retry-count:b: 0
```

The per-device `persist` filesystem and modem runtime stores changed during the
normal Android boot, as expected. `fsg`, `fsc`, the three `mdm1m9kefs` images,
and `mdm1m9kefsc` remained unchanged. Both reads of every critical A1 image
matched.

## A1 postmarketOS result

The complete, hash-verified `v0.2.0-alpha.1` release set was installed exactly
as documented: rootfs to `userdata` through fastbootd, then the matching
filtered DTBO and boot image to slot B. Slot-B stock images were backed up and
verified first.

Result: **boot success**. USB NCM answered at `172.16.42.1` after nine seconds,
SSH opened after another ten seconds, and runtime identity showed:

```text
Linux 6.17.0-sm8150-hotdog-clean
androidboot.slot_suffix=_b
pmos_boot_uuid=09349dcb-61c5-48d1-8cb9-4e6ec5343d2d
pmos_root_uuid=375adfc5-dc0c-4d18-af98-21ff4ae204ee
root=/dev/loop0p2 ext4 rw
```

The static PM8150/IMEM reboot helper returned the handset to bootloader
fastboot. The original `dtbo_b` and `boot_b` were restored from A1 and slot A
was selected without another Android boot.

Therefore OxygenOS 10 first boot does **not** reproduce the reported failure.
LineageOS B/C testing against this baseline would not isolate the original
phenomenon. The next controlled baseline must use the relevant OxygenOS 12
firmware/package; only if OOS12-to-pmOS fails should Lineage installer and
first-boot bisection resume.

## Current status

| Checkpoint | Status | Result |
| --- | --- | --- |
| Isolated Git worktree and branch | complete | `investigate/lineage-boot-state` |
| PRE0 GPT/LUN inventory | complete | Six LUNs, 4096-byte sectors |
| PRE0 critical double backup | complete | 39 of 39 pairs match |
| PRE0 partition baseline | complete | 116 partitions, `userdata` excluded |
| Stock plan excluding `persist` | complete | XML and 54 payloads verified |
| Authenticated stock data flash | complete | 44 ACKs; 43 readbacks plus `userdata` ACK |
| Stock GPT primary/backup | complete | 12 writes and 12 byte-identical readbacks |
| A0 capture | complete | Stock GPT, slot uninitialized, Android never booted |
| A0 postmarketOS/mainline boot | skipped | Not a realistic user path |
| A1 capture | complete | 16 changed objects; slot A initialized and successful |
| A1 postmarketOS/mainline boot | complete | Success with `v0.2.0-alpha.1` |
| OOS12 baseline | pending | Required to reproduce the reported failure |
| B | pending | Not started |
| C | pending | Not started |
