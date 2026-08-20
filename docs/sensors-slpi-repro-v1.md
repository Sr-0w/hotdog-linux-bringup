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

The hardware candidate is currently **BLOCKED**. Two captured files are not
accepted by the standard JSON parser: `sns_cm.json` contains the literal
`:wq!` in its `soc_id` array, and the captured MMC5603 file contains a raw tab
inside a string. Their bytes are intentionally unchanged. Hash verification
proves identity only; it does not prove that the Qualcomm parser accepts the
format. The manifest records both files and the required parser-evidence gate.

One 45-set file has an explicit tracked overlay:
`firmware/sensors/config-curated/45/msmnile_mmc5603nj.json`. Its CRLF bytes
match the 5962-byte physical OOS11 capture. The pool copy is 5742-byte LF and
must not silently replace the captured bytes.

Verify both candidates from the branch root:

```sh
python3 scripts/sensors-slpi-repro.py verify --repo-root . --variant 45
python3 scripts/sensors-slpi-repro.py verify --repo-root . --variant 47
```

`verify` is an identity check and can pass for an opaque blocked file. Normal
staging refuses the blocked candidate. `--allow-blocked` is only for an
offline parser experiment and must not be treated as hardware-ready:

```sh
python3 scripts/sensors-slpi-repro.py verify \
  --repo-root . --variant 45 --strict-json
```

This command is expected to fail for the current captured bytes until
Qualcomm parser acceptance is evidenced.

When the local v16 build and SLPI capture roots are present under the same
baseline root, verify all 37 recorded external artifacts in one pass:

```sh
python3 scripts/sensors-slpi-repro.py verify-external \
  --artifact-root /path/to/hotdog-r6-rebaseline
```

Stage only the Git-owned config files into an offline root:

```sh
python3 scripts/sensors-slpi-repro.py stage \
  --repo-root . --variant 45 --allow-blocked --out-root /path/to/offline-root
```

When a separately acquired sensor root is available, stage its
`sns_reg.conf`, `sns_reg_version`, `config/` and `registry/` inputs explicitly:

```sh
python3 scripts/sensors-slpi-repro.py stage \
  --repo-root . --variant 47 \
  --allow-blocked \
  --external-root /path/to/captured-sensors-root \
  --out-root /path/to/offline-root
```

The external root must contain regular files (no symlinks) at
`sns_reg.conf`, `sns_reg_version`, `config/` and `registry/`. Its `config/`
must contain exactly the selected filenames and byte-identical hashes; extras,
omissions and collisions are rejected. The external config is verified but
never copied over the Git-owned selection. The helper never fetches these from
a phone.

## Byte-preserving rollback

Snapshot a captured runtime root before changing it:

```sh
python3 scripts/sensors-slpi-repro.py snapshot \
  --served-root /path/to/captured-sensors-root \
  --out /path/to/sensor-snapshot \
  --quiesced
```

`--quiesced` is a required assertion that the source is offline and immutable.
The helper inventories and hashes the source before and after copying and
rejects a changed file set. The snapshot contains a payload tree plus a
strict per-file JSON record of path, size, SHA256 and mode. Restore validates
the complete payload before touching the target, restores through a sibling
staging directory, then atomically replaces the target. An existing target is
kept as a temporary backup until the post-check succeeds; `--replace` is
required to enable that replacement:

```sh
python3 scripts/sensors-slpi-repro.py restore \
  --snapshot /path/to/sensor-snapshot \
  --target /path/to/offline-sensors-root \
  --replace
```

The repository currently has registry counts and a `sns_reg_version` hash in
logs, but not the bytes of `sns_reg.conf` or the 121-file curated registry.
Therefore a byte-for-byte runtime rollback is not yet available until an
external capture is supplied. The rollback contract preserves regular-file
content, size, SHA256 and permission mode; it does not preserve owner/group,
ACLs, xattrs, timestamps, hardlinks or directory metadata.

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
