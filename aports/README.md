# Portable aport snapshots

This directory is the small, public, portable subset of the hotdog pmaports
work needed to resume the port without copying the full development checkout.

## Canonical source and snapshots

The canonical development tree is:

```text
src/postmarketos/pmaports-sm8150
```

`aports/` is a reviewed mirror, not a second authoritative tree. Make package
changes in the canonical checkout, then update and verify the snapshots with:

```bash
./scripts/sync-aport-snapshots.sh
./scripts/sync-aport-snapshots.sh --apply
```

The default direction is canonical checkout to snapshots. `--apply` moves an
existing destination directory to `build/aport-backups/` before replacing it
and verifies the copy with `diff -qr`. To bootstrap a fresh pmaports checkout
from this repository, use the reverse direction deliberately:

```bash
./scripts/sync-aport-snapshots.sh --to-pmaports --apply \
  --target-pmaports /path/to/pmaports-sm8150
```

Only the current bring-up packages are mirrored:

- `device-oneplus-hotdog`
- `firmware-oneplus-hotdog` (APKBUILD metadata only)
- `linux-postmarketos-sm8150-staging`
- `linux-postmarketos-qcom-sm8150`
- the boot-proven `linux-oneplus-hotdog-lineage414` snapshot

Snapshots permit only reviewed text package inputs: `APKBUILD`, kernel configs,
patches, deviceinfo, and device scripts. They intentionally do not contain
firmware blobs, APKs, source archives, boot images, or secrets. The existing
`stock-hotdog-dtbpack.dtb` remains the sole binary exception: its use and
checksum are already declared by the legacy 4.14 APKBUILD.

## Development-only access

The normal `device-oneplus-hotdog` package does not grant passwordless `doas`.
`device-oneplus-hotdog-bringup` is an explicit, optional subpackage for a
dedicated development phone only; it owns the installed `doas` policy that
enables unattended bring-up and flash/test cycles for members of `wheel`.
Do not install it on a personal or production device.
