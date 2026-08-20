# Sensors/SLPI reproducibility baseline v1

This branch records the offline candidate for the OnePlus 7T Pro hotdog
sensor bring-up. It does not contain proprietary firmware, a registry dump,
or any phone operation.

The machine-readable source of truth is
[`manifests/sensors-slpi-v1.json`](../manifests/sensors-slpi-v1.json). The
staging and rollback helper is
[`scripts/sensors-slpi-repro.py`](../scripts/sensors-slpi-repro.py).

## Selection policy

The 65 JSON files under `firmware/sensors/config/` are an OOS11 source pool,
not a runtime directory. The baseline runtime set is exactly 45 files. The
47-file candidate adds only `alsps.json` and `msmnile_alsps.json`; it is kept
as a separate candidate because ALSPS CCT provenance is unresolved.

One 45-set file has an explicit tracked overlay:
`firmware/sensors/config-curated/45/msmnile_mmc5603nj.json`. Its CRLF bytes
match the 5962-byte physical OOS11 capture. The pool copy is 5742-byte LF and
must not silently replace the captured bytes.

Verify both candidates from the branch root:

```sh
python3 scripts/sensors-slpi-repro.py verify --repo-root . --variant 45
python3 scripts/sensors-slpi-repro.py verify --repo-root . --variant 47
```

When the local v16 build and SLPI capture roots are present under the same
baseline root, verify all 37 recorded external artifacts in one pass:

```sh
python3 scripts/sensors-slpi-repro.py verify-external \
  --artifact-root /path/to/hotdog-r6-rebaseline
```

Stage only the Git-owned config files into an offline root:

```sh
python3 scripts/sensors-slpi-repro.py stage \
  --repo-root . --variant 45 --out-root /path/to/offline-root
```

When a separately acquired sensor root is available, stage its
`sns_reg.conf`, `sns_reg_version`, `config/` and `registry/` inputs explicitly:

```sh
python3 scripts/sensors-slpi-repro.py stage \
  --repo-root . --variant 47 \
  --external-root /path/to/captured-sensors-root \
  --out-root /path/to/offline-root
```

The external root must contain regular files (no symlinks) at
`sns_reg.conf`, `sns_reg_version`, `config/` and `registry/`. The helper never
fetches these from a phone.

## Byte-preserving rollback

Snapshot a captured runtime root before changing it:

```sh
python3 scripts/sensors-slpi-repro.py snapshot \
  --served-root /path/to/captured-sensors-root \
  --out /path/to/sensor-snapshot
```

The snapshot contains a payload tree plus a per-file JSON record of path,
size, SHA256 and mode. Restore it only into an offline target; `--replace` is
required to remove an existing target:

```sh
python3 scripts/sensors-slpi-repro.py restore \
  --snapshot /path/to/sensor-snapshot \
  --target /path/to/offline-sensors-root \
  --replace
```

The repository currently has registry counts and a `sns_reg_version` hash in
logs, but not the bytes of `sns_reg.conf` or the 121-file curated registry.
Therefore a byte-for-byte runtime rollback is not yet available until an
external capture is supplied.

## Image and SLPI inputs

The manifest records exact size and SHA256 for the known complete v16 image:
kernel `Image`, hotdog DTB, initramfs, rootfs disk image, raw boot image and
AVB boot image. It also records the kernel source commit/config and the exact
SLPI 00121 `slpi.mbn` plus all `slpi.mdt`/`slpi.b00..b20` split hashes. These
inputs remain local captures and are intentionally not copied into this
branch. Reassemble an ELF only with the recorded split set using
`scripts/slpi/build-slpi-elf.py`.

The current pmaports recipes do not install SLPI or sensor registry data;
`hexagonrpcd` supplies mappings only. No pmaports package change is justified
until the external registry and firmware provenance are complete.
