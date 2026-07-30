# Generated artifacts

Large or device-specific artifacts are deliberately excluded from Git. A fresh
clone contains the source, scripts, package snapshots, and documentation needed
to recreate them, but not ready-to-flash images.

## Local directories

| Directory | Content |
|---|---|
| `src/` | External source repositories. |
| `build/` | Compiled helpers, kernels, DTBs, and initramfs archives. |
| `images/` | Android boot images and postmarketOS disk images. |
| `logs/` | Hardware runs, dmesg captures, and watcher state. |
| `android-dumps/` | Device-specific stock partition backups. |
| `pmbootstrap-work/` | pmbootstrap chroots, packages, and work state. |
| `rootfs/` | Mounted or extracted root filesystem work. |
| `tools/` | Downloaded host and target utilities. |

These paths are ignored and must not be added with `git add -f`.

## Validated artifact classes

The current mainline cycle requires four local files:

1. Linux 6.17 `Image`
2. final hotdog mainline DTB
3. wrapped postmarketOS initramfs
4. downstream 4.14 no-paint bridge image

`scripts/test-mainline617-pmos-full.sh` is the source of truth for their local
paths and expected hashes. The paths are intentionally inside ignored build and
image directories.

## Rebuilding the mainline DTB

The recommended offline rebuild path is the complete K1 orchestrator:

```bash
./scripts/bootstrap-sources.sh --sm8150-k1
./scripts/build-mainline-k1-dtb-chain.sh
```

By default, the orchestrator checks out pinned kernel commit `379d8fe...` in a
temporary worktree, applies the tracked hotdog DTS patch, and reproduces base
DTB `44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49`.
The ordered transforms must then reproduce final K1 DTB
`cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440`.
It writes ordered stage directories, `final.dtb`, `SHA256SUMS`, and a manifest
under a timestamped `build/experiments/` directory.

For targeted debugging, the individual stages are:

```bash
./scripts/build-mainline-k1-base-dtb.sh
./scripts/build-mainline-kexec-lowbank-dtb.sh
./scripts/build-mainline-lowbank-firmware-gap-dtb.sh
./scripts/build-mainline-ufs-smmu-bypass-dtb.sh
./scripts/build-mainline-ufs-no-ice-dtb.sh
./scripts/build-mainline-pmos-boot-dtb.sh
```

Each stage writes a timestamped directory under `build/experiments/` and emits
hashes. Pass explicit input paths when reproducing a stage on another host.
The optional stock-DTB check in the firmware-gap stage is evidence-only and is
not required to build the hash-pinned output.
These steps intentionally include temporary bring-up hacks: the low-bank RAM
constraint, firmware gap reservation, UFS/QUP/DWC3 Apps SMMU bypasses, and the
UFS ICE removal.

## Rebuilding the initramfs wrapper

```bash
./scripts/build-mainline-pmos-wrapper-initramfs.sh \
  --base-cpio build/path/to/initramfs-pmos.cpio
```

The default output replaces the framebuffer paint helper with a wait-only
helper. `--keep-fb-paint` exists only for historical comparison and should not
be used for the normal mainline cycle.

When a static stage helper is supplied, the default `handoff` profile traces
the transition from `/init` into `init_2nd.sh`. The `udev` profile narrows a
stage-two stall without changing the kernel or DTB:

```bash
./scripts/build-mainline-pmos-wrapper-initramfs.sh \
  --base-cpio build/path/to/initramfs-pmos.cpio \
  --userspace-stage-helper build/path/to/hotdog-userspace-stage \
  --userspace-stage-profile udev
```

It overlays instrumented copies of `init_2nd.sh` and
`init_functions_2nd.sh`. Cells 6-10 report `setup_udev` entry, return from
`udevd`, return from `udevadm trigger`, return from `udevadm settle`, and
return from `setup_usb_network`.

The `udev-bounded` profile uses the same markers but gives each udev command
15 seconds. Without an explicit helper it uses the original shell-based
diagnostic runner. That path is retained for reproducing older artifacts, but
it may itself stop before ash returns the background child PID.

The `udev-bounded-deep` profile keeps the same 15-second command limits but
uses cells 6-10 for `init_2nd.sh` entry, function-source return, watchdog
return, aggregate `setup_udev` return, and USB-network return. It is useful
when the per-command profile never reaches its first udev marker.

For a bounded launch that does not depend on ash background-job behavior, build
the tracked static fork/exec helper and add it to either bounded profile:

```bash
./scripts/build-hotdog-bounded-exec.sh
./scripts/build-mainline-pmos-wrapper-initramfs.sh \
  --base-cpio build/path/to/initramfs-pmos.cpio \
  --userspace-stage-helper build/path/to/hotdog-userspace-stage \
  --userspace-stage-profile udev-bounded-deep \
  --bounded-exec-helper \
    build/tools/hotdog-bounded-exec/hotdog-bounded-exec
```

The helper forks before `execvp()`, measures a monotonic 15-second deadline,
terminates the child process group with `SIGTERM` and then `SIGKILL`, and
returns status 124 to stage two. Its builder tests successful execution, exact
exit-status propagation, and a real timeout under QEMU. This remains a
bring-up diagnostic: continuing after a failed udev command is not the final
production policy.

The diagnostic-only `udev-skip` profile omits `setup_udev`, marks that bypass
in cells 6-7, brackets `setup_usb_network` with cells 8-9, and marks return
from `start_unudhcpd` with cell 10:

```bash
./scripts/build-mainline-pmos-wrapper-initramfs.sh \
  --base-cpio build/path/to/initramfs-pmos.cpio \
  --userspace-stage-helper build/path/to/hotdog-userspace-stage \
  --userspace-stage-profile udev-skip
```

The builder rejects the profile if the generated second stage still contains
an executable `setup_udev` line. This profile only separates USB bring-up from
the udev stall; it must not become the normal boot policy.

For a recovery deadline that does not depend on a shell loop, build the tracked
static supervisor and add it to the wrapper:

```bash
./scripts/build-hotdog-rescue-supervisor.sh
./scripts/build-mainline-pmos-wrapper-initramfs.sh \
  --base-cpio build/path/to/initramfs-pmos.cpio \
  --rescue-supervisor \
    build/tools/hotdog-rescue-supervisor/hotdog-rescue-supervisor
```

The static process uses `CLOCK_MONOTONIC`, arms the APSS watchdog for the
hardware-safe 32-second maximum, requests bootloader mode in IMEM, and kicks
the hardware until `hotdog_rescue_watchdog_sec` expires. It disarms only after
the rootfs marker. At the logical deadline it calls `RESTART2(bootloader)`
directly; if that syscall returns, it stops feeding the hardware fallback.
This option is mutually exclusive with the older split RESTART2 and APSS
helpers. It remains a bring-up safety mechanism, not part of the intended
production package.

## Promoting a new artifact

A newly generated file is not validated merely because it builds. Promotion
requires:

1. offline format and architecture checks
2. a recorded SHA256
3. a rescue path
4. a successful hardware boot
5. a new userspace boot ID
6. rootfs and USB verification
7. an update to the hash-pinned launcher and documentation

Historical hashes, experiment narratives, and generated logs remain local
under ignored workspace directories. Promote only sanitized conclusions and
reproducible inputs into Git.
