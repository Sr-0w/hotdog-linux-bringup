# Build and test workflow

Last updated: 2026-08-26

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

- `linux-oneplus-hotdog-mainline617-clean` `6.17.0-r8`
- `device-oneplus-hotdog` `3-r36`
- `firmware-oneplus-hotdog` `20241212-r7`

These revisions move as experiments are accepted. The source tree and built
package metadata, not this list alone, are authoritative.

## 3. Build the package-shaped image

```bash
HOTDOG_PMAPORTS_SM8150="$PWD/src/postmarketos/pmaports" \
HOTDOG_PMBOOTSTRAP_WORK="$PWD/pmbootstrap-work-current" \
./scripts/pmbootstrap-hotdog.sh -j 32 -E 9170 install --no-sparse \
  --no-recommends \
  --add polkit-elogind,device-oneplus-hotdog-plasma-mobile-apps,device-oneplus-hotdog-sensors
```

The explicit app and sensor packages avoid a moving edge recommendation set;
the 2026-08-25 edge metadata recommended `index`, which is absent from this
pinned pmaports snapshot. Do not silently replace the curated application set
with whichever recommendations happen to resolve on the build day.

The device package generates the header-v2, 100663296-byte AVB boot envelope
through its `boot-deploy` postprocess. Verify the kernel, DTB, initramfs,
modules, firmware, filesystems, AVB footer and complete hashes before hardware
use. Older raw images can be checked without modifying them with:

```bash
./scripts/wrap-pmaports-boot-avb.sh \
  --boot-image /path/to/generated/boot.img \
  --outdir build/pmaports-mainline616-avb
```

The 9170 MiB addition produces the validated 14096007168-byte userdata payload
and places the backup GPT at its true end. The nested-GPT assembler remains a
laboratory deployment format while the final upstream installer design is
pending:

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

### Installing a kernel package on a running phone

`apk add` of a kernel package replaces every module in the rootfs, but the
kernel image, DTB and initramfs are read from the `boot_b` partition. Installing
without flashing runs one build's kernel against another build's modules, so
install and flash are one operation, never two independent decisions:

```bash
scp "$APK" root@172.16.42.1:/tmp/k.apk && ssh root@172.16.42.1 'apk add --allow-untrusted /tmp/k.apk'
scp root@172.16.42.1:/boot/boot.img boot.img
./scripts/flash-boot-b-from-pmos-ssh.sh --image boot.img --image-sha256 "$SHA" --serial "$SERIAL" \
  --expected-source-boot-id "$BOOT_ID" --expected-source-kernel "$RELEASE" --reboot
```

"Only a module changed" is never a reason to leave the partition stale: a
Kconfig change propagates into the resolved `.config` and therefore into every
module. Skipping the flash on 2026-08-26 produced a corrupted display and a
`dsi_err_worker` fault that flashing the matching image cleared outright.

### Rebooting

Never reboot with busybox `reboot` over SSH. It leaves the root filesystem to
replay its journal on the next boot, one such boot came up with sshd missing,
and twice the phone ended in EDL needing physical recovery:

```bash
./scripts/hotdog-reboot.sh
```

It stops the runlevel first, detaches with `setsid` — without which the sequence
dies with the SSH session and nothing reboots at all — and then checks
`dmesg | grep -c "recovering journal"` on the way back. A non-zero count means
the shutdown was dirty. `fastboot reboot` is the one path observed clean.

### When SSH is down

`device-oneplus-hotdog` runs an auto-login root getty on `ttyGS0`, which the
host sees as `/dev/ttyACM0`. It depends on neither sshd nor the network, so it
works on any boot that reaches userspace:

```bash
./scripts/hotdog-usb-console.sh 'rc-service sshd restart' 15
```

The port must be opened with `clocal`, otherwise the open waits for a carrier
the USB gadget never asserts and hangs. Setting `c_cflag` from scratch without
the baud bits selects `B0`, which means *hang up the line* — that mistake made
this console look absent for an entire evening, and the phone was handed back
to its owner to type commands that could have been sent from here. An empty
read never proves there is no console.

### Gates

Two scripts split hardware acceptance along the line of what needs a hand:

- `scripts/gate-sm8150-617-runtime.sh` — 35 checks that need no gesture.
  It exists because the first global gate was walked by hand and the SSC sensor
  regression was seen exactly once.
- `scripts/gate-sm8150-617-physical.sh` — pop-up camera, torch and flash,
  haptics, proximity, ambient light and orientation. It triggers, then asks; the
  operator's answer is the verdict. `SKIP="popup flash"` drops named tests.

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
