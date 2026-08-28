# OxygenOS 12 slot-A control for the public install contract

Date: 2026-08-28

## Why this control exists

An HD1911 tester followed the Alpha 5 installation guide, flashed the published
`super`, `dtbo_b` and `boot_b` artifacts, and consistently returned to the
bootloader before Linux left any pstore record. The same artifact hashes boot on
the development handset. This exposes an unrecorded dependency on the handset's
pre-installation state, not an artifact-corruption problem.

The development handset inherited a LineageOS top-level `vbmeta_b` with flags
`3` (`HASHTREE_DISABLED | VERIFICATION_DISABLED`). Alpha 5 does not publish or
flash `vbmeta`, so a handset starting from OxygenOS retains a stock top-level
vbmeta with flags `0`. That difference was a plausible hidden prerequisite.

## Regional firmware comparison

The official HD1911 (India) and HD1913 (Europe) OxygenOS 12 F.22 full OTA
payloads were downloaded and compared by partition name, size and SHA-256.

- `abl`, `xbl`, `xbl_config`, `boot`, `dtbo` and top-level `vbmeta` are
  byte-identical between the two regions.
- `vbmeta_system` differs because the regional dynamic system content differs.
- The common stock top-level vbmeta chains `boot`, `dtbo`, `recovery` and
  `vbmeta_system` to signed keys.

The early failure therefore cannot be explained merely by HD1911 versus HD1913
F.22 boot firmware.

## Hardware vbmeta A/B control

The running Linux 6.17 development image was tested on slot B with two 64 KiB
top-level vbmeta images derived from the same HD1911 F.22 source:

1. the stock image, unchanged, with flags `0`;
2. the same image with only bytes 120--123 changed from big-endian `0` to `3`.

Both configurations booted the same kernel and userspace. With flags `0`, ABL
passed the vbmeta digest and `androidboot.veritymode=enforcing`; with flags `3`,
those chain-derived parameters disappeared as expected. Both boots reported an
unlocked device and orange verified-boot state.

This proves that flags `3` alter AVB processing, but it does **not** reproduce
the tester's failure on the development handset. Missing `vbmeta` remains a
candidate dependency on another ABL/firmware baseline, not a confirmed sole
cause.

The original known-good slot-B vbmeta was restored after the control.

## Next discriminating experiment

Create a stock HD1913 F.22 OxygenOS 12 control on slot A while preserving slot B
and a complete pmOS `super` backup. Confirm that stock OxygenOS boots, then
reproduce the published Alpha 5 installation in its documented order before
adding any correction. If it fails like the external handset, introduce one
change at a time, beginning with top-level vbmeta.

Because physical `super` is shared by both slots, an OxygenOS control also
temporarily removes the pmOS root layout used by slot B. The preflight therefore
backs up the full current `super`, every F.22-targeted physical slot-A partition,
the shared `oem_stanvbk`, boot-control metadata and the device-specific modem and
persist state. Raw dumps, hashes tied to private hardware and runtime logs remain
outside Git.

## Stock slot-A baseline result

The control was prepared from the model-correct HD1913/EU F.22 full OTA. Its
payload manifest describes one 7,511,998,464-byte dynamic-partition group with
Virtual A/B snapshots enabled. A sparse `super` image was rebuilt with all 15
slot-A logical partitions, three metadata slots and an empty reserved slot-B
group. Converting it back to raw form, reading it with `lpdump`, unpacking every
logical partition and comparing each image byte-for-byte against the OTA all
passed before flash.

The existing slot-A firmware was already F.22 for most boot-critical
partitions. Only the partitions that differed were written: `LOGO_a`, `boot_a`,
`dtbo_a`, `opproduct_a`, `recovery_a`, `vbmeta_a`, `vbmeta_system_a`, the shared
`oem_stanvbk`, and physical `super`. Bootloader fastboot correctly refused the
two critical partitions; recovery fastbootd wrote them without changing the
critical-unlock state.

The first OxygenOS boot entered stock recovery because the previous encrypted
userdata was incompatible. After an explicitly authorised recovery data wipe,
the same slot reached OxygenOS Android userspace and enumerated ADB. This proves
that the reconstructed EU F.22 slot-A baseline is bootable.

The next step is now narrower: reproduce the exact Alpha 5 public installation
on top of this known-stock state. A failure there will be directly comparable to
the external HD1911 report. No vbmeta correction will be introduced until that
published sequence has first been observed unchanged.

## Exact Alpha 5 reproduction

The published Alpha 5 boot, DTBO and decompressed rootfs were installed on slot
A over the validated stock baseline. Their hashes matched the public release;
the kernel APK was verified as a package artifact and was not treated as a
flashable partition. Stock OxygenOS `vbmeta_a`, flags `0`, was deliberately left
unchanged.

ABL accepted the image set and entered the Alpha 5 kernel and initramfs. The
boot then stopped in `mount_subpartitions()` while `kpartx` processed physical
`super`. This is a real release defect, but it is later than the external
bootloader-return symptom and therefore may coexist with a second issue.

The released rootfs is a valid 4,523,556,864-byte nested GPT image using
4096-byte logical sectors. Its two filesystems are clean and its UUIDs exactly
match the boot command line. Physical `super`, however, is 15,032,385,536 bytes.
After the shorter image is flashed, its backup GPT remains at the end of the
short image instead of the end of the physical partition. The kernel reports
that mismatch and `kpartx -afs` blocks before the initramfs timeout can run.

A corrected control image was generated without changing boot, DTBO or UUIDs:

- extend the nested image to the exact physical `super` size;
- relocate the backup GPT to the real final logical sector;
- extend partition 2 to the final usable sector;
- grow the existing ext4 root filesystem;
- convert the result to Android sparse format.

The resulting GPT, both filesystems and sparse-to-raw byte-for-byte round trip
pass offline validation. Hardware validation of this corrected rootfs is the
next action.

The final release direction did not retain this repaired legacy path. Restoring
the matched clean-6.17 `userdata`, boot and DTBO set reached Plasma Mobile and
SSH. A release package built from that exact atomic set was then flashed from
its generated assets, read back at boot and DTBO, and monitored for 918 seconds
with one stable boot ID and no fastboot or EDL transition. The maintained 6.17
initramfs uses a 4096-byte-sector loop device instead of the obsolete `kpartx`
path.

## Why EDL is not the next control

The external handset showed its original failure before its later EDL restore,
so EDL cannot explain the original report. In addition, the development handset
does not yet have a complete restore set for every partition a Firehose package
may overwrite, every UFS LUN, userdata and partition-table state. A model-correct
EDL restore would therefore add risk and several new variables while a concrete
release defect is already reproduced.

EDL remains out of scope for this control. If it is ever considered separately,
it requires a complete readback and explicit plan for the exact Firehose package
before any write.

## Safety and publication consequences

- Do not use EDL as part of this experiment.
- Never reset or write a device presenting Qualcomm 9008 or 900e USB identity.
- Keep slot-B boot, DTBO and vbmeta artifacts available independently of
  `super` recovery.
- Do not change the public install guide or publish a replacement vbmeta until
  the stock-slot control reproduces and then resolves the external failure.
- A final public vbmeta, if required, must be generated for this project and
  must not reuse private LineageOS partition metadata.
