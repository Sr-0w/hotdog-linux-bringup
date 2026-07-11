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

The current transformation chain is:

```bash
./scripts/build-mainline-lowbank-firmware-gap-dtb.sh
./scripts/build-mainline-ufs-smmu-bypass-dtb.sh
./scripts/build-mainline-ufs-no-ice-dtb.sh
./scripts/build-mainline-pmos-boot-dtb.sh
```

Each stage writes a timestamped directory under `build/experiments/` and emits
hashes. Pass explicit input paths when reproducing a stage on another host.

## Rebuilding the initramfs wrapper

```bash
./scripts/build-mainline-pmos-wrapper-initramfs.sh \
  --base-cpio build/path/to/initramfs-pmos.cpio
```

The default output replaces the framebuffer paint helper with a wait-only
helper. `--keep-fb-paint` exists only for historical comparison and should not
be used for the normal mainline cycle.

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
