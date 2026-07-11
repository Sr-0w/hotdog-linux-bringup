# Contributing

Contributions are welcome, especially from owners of OnePlus 7T Pro variants
and developers familiar with Qualcomm SM8150.

## Before opening a change

- Read `README.md`, `docs/status.md`, and `docs/device-safety.md`.
- Search existing issues and the current documentation.
- Keep generated binaries, phone dumps, firmware, and full logs out of Git.
- Do not include credentials or unique device identifiers.

## Hardware reports

A useful report includes:

- model number and regional variant
- kernel repository and exact commit
- config, DTB, and initramfs hashes
- boot method
- active slot and bootloader state
- observable screen and USB behavior
- relevant dmesg excerpts
- whether recovery occurred automatically or required physical input

## Pull requests

Keep changes focused. Separate pmaports packaging, kernel patches,
documentation, and experimental tooling when they can be reviewed
independently.

Before submitting:

```bash
git diff --check
bash -n scripts/*.sh
shellcheck -x scripts/changed-script.sh
./scripts/validate-mainline-go-cycle.sh
```

Run only the checks relevant to the changed path. Hardware-affecting pull
requests must describe the rescue path and whether the result was tested on a
real device.

## Commit messages

Use short, imperative summaries such as:

```text
Document mainline UFS bring-up
Make framebuffer probe wait-only
Add DWC3 SMMU bypass builder
```

## Licensing

By contributing, you agree that your original contribution is available under
the repository license. Files derived from third-party projects must retain
their original license and attribution.
