# Linux upstream submission queue

The prepared patch sets live under [`upstream/2026-08-11`](../upstream/2026-08-11).
They are based on linux-next 20260810 at `3d08ff75a47a` and use the DCO identity
`Robin Snyders <robin@snyders.xyz>`.

No patch in this directory has been mailed. The files are immutable submission
artifacts: revise the source branch and regenerate a complete versioned series
instead of editing a mailed patch in place.

## Queue

| Series | Patches | State | Remaining gate |
| --- | ---: | --- | --- |
| Q6AFE DisplayPort playback widget | 1 | Send-ready | None |
| SM8150 download-mode register | 1 | Send-ready | None; six clean hardware reboots were recorded |
| Qualcomm SMB5 charger support | 3 | Send-ready | None; conservative limits and guarded traces were hardware-validated |
| OnePlus 7T Pro initial device tree | 2 | Preflight | Boot the exact rebased DTB once and verify the initial hardware subset |

The device-tree series intentionally excludes native panel support, audio,
Type-C role switching, cameras, NFC, haptics and other experimental pieces.
Those require focused follow-up series with their own bindings and evidence.

## Validation completed

- all source branches are rebased on linux-next 20260810;
- every commit carries the required `Signed-off-by` trailer;
- Q6AFE and qcom_smbx objects build with `ARCH=arm64 LLVM=1`;
- the SMB5 binding passes targeted `dt_binding_check`;
- the Hotdog DTB builds and passes full `CHECK_DTBS=y` validation without a
  diagnostic;
- all patches pass `scripts/checkpatch.pl --strict`, except for the expected
  generic MAINTAINERS reminder on the newly added DTS; the Qualcomm ARM64
  device-tree entry already covers that path;
- the final three-patch SMB5 series produces byte-for-byte the same source
  result as the previously tested six-commit development series.

## Final Hotdog hardware gate

Before mailing the OnePlus device-tree series, apply it to the stated
linux-next base, build `qcom/sm8150-oneplus-hotdog.dtb`, and boot that exact
artifact without carrying unrelated project patches. Verify at minimum:

1. direct kernel entry and visible simple-framebuffer output;
2. UFS discovery and root filesystem access;
3. USB peripheral networking or ACM access;
4. S6SY761 touch and both volume keys;
5. WiFi and the ADSP/MPSS remote processors;
6. a clean software reboot without Qualcomm 900e download mode.

Record the exact commit, DTB hash and result in `docs/evidence` before removing
the preflight hold.

## Dry-run commands

Run from the repository root after configuring `git send-email`. These commands
only render the messages and recipients; they do not send mail.

```sh
git send-email --dry-run \
  --to='Mark Brown <broonie@kernel.org>' \
  --cc-cmd='./scripts/git-send-email-cc.sh upstream/2026-08-11/q6afe-v1/recipients.txt' \
  upstream/2026-08-11/q6afe-v1/0001-*.patch

git send-email --dry-run \
  --to='Bjorn Andersson <andersson@kernel.org>' \
  --to='Konrad Dybcio <konradybcio@kernel.org>' \
  --cc-cmd='./scripts/git-send-email-cc.sh upstream/2026-08-11/sm8150-dload-v1/recipients.txt' \
  upstream/2026-08-11/sm8150-dload-v1/0001-*.patch

git send-email --dry-run \
  --to='Sebastian Reichel <sre@kernel.org>' \
  --cc-cmd='./scripts/git-send-email-cc.sh upstream/2026-08-11/qcom-smbx-v1/recipients.txt' \
  upstream/2026-08-11/qcom-smbx-v1/*.patch

git send-email --dry-run \
  --to='Bjorn Andersson <andersson@kernel.org>' \
  --to='Konrad Dybcio <konradybcio@kernel.org>' \
  --cc-cmd='./scripts/git-send-email-cc.sh upstream/2026-08-11/oneplus-hotdog-v1/recipients.txt' \
  upstream/2026-08-11/oneplus-hotdog-v1/*.patch
```

For a real submission, first repeat the dry run and inspect every generated
header. Then replace `--dry-run` with `--confirm=always`. Send each directory as
an independent thread; do not combine the four series.

When posting a revision, regenerate the full series with `--subject-prefix` set
to the new version, add a cover-letter changelog, and keep the original message
IDs available for `b4` and lore references.
