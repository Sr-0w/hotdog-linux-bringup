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

Create a stock HD1911 F.22 OxygenOS 12 control on slot A while preserving slot B
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

## Safety and publication consequences

- Do not use EDL as part of this experiment.
- Never reset or write a device presenting Qualcomm 9008 or 900e USB identity.
- Keep slot-B boot, DTBO and vbmeta artifacts available independently of
  `super` recovery.
- Do not change the public install guide or publish a replacement vbmeta until
  the stock-slot control reproduces and then resolves the external failure.
- A final public vbmeta, if required, must be generated for this project and
  must not reuse private LineageOS partition metadata.
