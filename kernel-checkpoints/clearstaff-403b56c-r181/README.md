# ClearStaff 403b56c + Hotdog r181 Kernel Checkpoint

This directory is the immutable source checkpoint for the last hardware-tested
OnePlus 7T Pro (`hotdog`) kernel before the clean SM8150 migration. It captures
the exact ClearStaff base and the complete postmarketOS patch queue, including
historical diagnostics and experiments that will not necessarily be ported to
the new kernel.

Do not edit this directory after the checkpoint tag is published. If a defect
is found, create a new checkpoint directory and tag instead.

## Exact identity

- Base repository: `https://github.com/ClearStaff/linux-sm8150-mainline-hotdog.git`
- Base commit: `403b56c33e2ccdda25d90378970a5e5b928dee19`
- Base tree: `1b8536e476eee041f3e04d0d258e5b8640c90d2c`
- Base parent: `a821ed440872b221acfa98ca34db1a5d1ae4bd96`
- Base subject: `Add OnePlus 7T Pro device tree`
- Ordered patch count: 153
- Reconstructed final source tree: `24c948f9555dff9feb7fbc48e54684cb638fa3ff`
- Source delta: 99 files, 14,630 insertions, 599 deletions
- Package identity: `linux-oneplus-hotdog-mainline616-6.16.0-r181.apk`
- Kernel release: `6.16.0-sm8150`

All remaining hashes and deterministic build metadata are recorded in
`metadata.env`. `SHA256SUMS` authenticates every checkpoint payload other than
itself.

## Contents

- `patches/`: byte-exact copy of all 153 patches from the r181 aport.
- `series`: authoritative patch order extracted from the r181 `APKBUILD`.
- `unapplied/`: the stray `0143` patch present beside the aport but absent from
  `source=`. It is preserved for provenance and is not part of the r181 tree.
- `APKBUILD.snapshot`: exact packaging and build recipe.
- `config.input`: configuration supplied to the package recipe.
- `config.resolved`: resulting configuration after `olddefconfig` with the
  recorded reference environment.
- `validate-mainline616-build.sh`: source, image, config, DTB and module
  contract used by the package.
- `cumulative.patch`: binary-capable cumulative diff from the base to the exact
  final source tree. This is a cross-check and convenient oracle; `series` is
  the authoritative historical ordering.
- `rebuild.sh`: applies the queue to a clean base checkout, verifies the exact
  final Git tree, and optionally performs the reference build.
- `verify-checkpoint.sh`: verifies hashes, queue completeness and metadata.

## Reconstruct the source

```sh
git clone https://github.com/ClearStaff/linux-sm8150-mainline-hotdog.git /tmp/hotdog-r181
git -C /tmp/hotdog-r181 checkout --detach 403b56c33e2ccdda25d90378970a5e5b928dee19
kernel-checkpoints/clearstaff-403b56c-r181/rebuild.sh /tmp/hotdog-r181
```

The final line must report tree
`24c948f9555dff9feb7fbc48e54684cb638fa3ff`.

To also rebuild the kernel, pass a separate output directory:

```sh
kernel-checkpoints/clearstaff-403b56c-r181/rebuild.sh \
  /tmp/hotdog-r181 /tmp/hotdog-r181-out
```

The build requires the dependencies listed in `APKBUILD.snapshot`. The
reference resolved config was produced with Clang/LLD 22.1.8, GNU Make 4.4.1
and GNU patch 2.8. The package recipe fixes the timestamp, build user, host and
version; those values are preserved in `metadata.env` and `rebuild.sh`.

## Reproduce from the source archive

The original GitHub archive is intentionally not duplicated in this repository
because it is 252,887,776 bytes. Its filename, size, SHA256 and SHA512 are
recorded in `metadata.env`. Verify the archive before extracting it, then
initialize a temporary Git repository at the extracted base if `rebuild.sh` is
used. The `cumulative.patch` can also be applied directly to that exact source
tree with `git apply` or `patch -p1`.

## Known preserved condition

The historical queue contains CRLF/trailing whitespace in additions to
`arch/arm64/boot/dts/qcom/sm8150-oneplus-common.dtsi`, introduced by the old
hardware-contract patch. The exact queue therefore does not pass a pristine
`git diff --check`. This is deliberately preserved because normalizing it
would change the final tree and break the checkpoint identity. New migration
work must not copy that formatting.

## Migration policy

This checkpoint is an oracle, not the patch stack for the new kernel. The
migration must recover validated behavior from the final tree and evidence,
then implement only the required contracts on the new SM8150 base. Historical
instrumentation, dead-end experiments and superseded fixes should remain here
rather than being mechanically rebased.
