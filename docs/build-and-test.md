# Build and test workflow

Last updated: 2026-08-13

This is the active source-to-hardware workflow. K1, D-series and kexec commands
are historical reproductions and are not the default release path.

## 1. Prepare the host

```bash
git clone https://github.com/Sr-0w/hotdog-linux-bringup.git
cd hotdog-linux-bringup
./scripts/bootstrap-host.sh
./scripts/bootstrap-sources.sh --sm8150-k1
cp pmbootstrap_v3.cfg.example pmbootstrap_v3.cfg
cp hotdog.env.example hotdog.env
./scripts/check-host-tools.sh
```

Review machine-local paths, job count and device identity in the ignored config
files. Never commit credentials, serials or dumps.

## 2. Validate the public tree

```bash
./scripts/validate-public-tree.sh
./scripts/sync-aport-snapshots.sh --to-pmaports
```

The second command is check-only. Review its diff before applying snapshots to
a separate pmaports checkout:

```bash
./scripts/sync-aport-snapshots.sh --to-pmaports --apply \
  --target-pmaports "$PWD/src/postmarketos/pmaports"
```

The tracked development packages are currently:

- `linux-oneplus-hotdog-mainline616` `6.16.0-r176`
- `device-oneplus-hotdog` `3-r22`
- `firmware-oneplus-hotdog` `20241212-r5`

These revisions move as experiments are accepted. The source tree and built
package metadata, not this list alone, are authoritative.

## 3. Build the package-shaped image

```bash
HOTDOG_PMAPORTS_SM8150="$PWD/src/postmarketos/pmaports" \
HOTDOG_PMBOOTSTRAP_WORK="$PWD/pmbootstrap-work-current" \
./scripts/pmbootstrap-hotdog.sh -j 32 install --split --no-sparse \
  --add polkit-elogind
```

The device package generates the header-v2, 100663296-byte AVB boot envelope
through its `boot-deploy` postprocess. Verify the kernel, DTB, initramfs,
modules, firmware, filesystems, AVB footer and complete hashes before hardware
use. Older raw images can be checked without modifying them with:

```bash
./scripts/wrap-pmaports-boot-avb.sh \
  --boot-image /path/to/generated/boot.img \
  --outdir build/pmaports-mainline616-avb
```

The nested-GPT assembler remains a laboratory reproducer, not the target
installer:

```bash
./scripts/assemble-pmaports-subpartition-image.sh \
  --boot-image /path/to/oneplus-hotdog-boot.img \
  --root-image /path/to/oneplus-hotdog-root.img \
  --outdir build/pmaports-mainline616-subpartitions
```

## 4. Offline acceptance

Before any write:

```bash
./scripts/bootstrap-host.sh --check-host
./scripts/validate-mainline-go-cycle.sh
./scripts/validate-current-candidates.sh
```

Also run the checks applicable to the changed layer: strict package build,
`checkpatch.pl`, `W=1`, GCC/LLVM builds, `dt_binding_check`, `dtbs_check`,
ShellCheck, libcamera/V4L2 tests or the relevant userspace test suite.

## 5. Hardware acceptance

Follow [device safety](device-safety.md). Resolve the exact target slot and
partition, verify a recovery image and watcher, write the candidate, read the
entire target back, compare SHA-256, then perform one supervised reboot.

A result is accepted only when a fresh boot ID proves the intended kernel,
DTB, modules and rootfs, the feature-specific test passes, USB recovery remains
available, and dmesg/pstore contain no new fault. Repeat cold boot,
suspend/resume and stress tests in proportion to the subsystem risk.

Feature helpers such as `deploy-test-mainline616-libcamera.sh`, the guarded
haptics tester and the collectors under `scripts/` supplement this contract;
they do not replace artifact identity and recovery checks.

## 6. Publish evidence

Record exact source commits, package versions, hashes, boot ID, hardware model,
commands, result, limitations and rollback outcome under `docs/evidence/`.
Update [status](status.md), [roadmap](roadmap.md) and affected subsystem docs in
the same commit. Generated images, full logs and private dumps remain ignored.

## Historical reproduction

`build-mainline-k1-dtb-chain.sh`, `test-mainline617-pmos-full.sh`, the D-series
launchers and the downstream bridge are preserved to reproduce the July
investigation. They are not the current direct-boot build or submission path.
