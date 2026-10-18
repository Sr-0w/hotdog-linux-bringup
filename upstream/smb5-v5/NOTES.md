# SMB5 v5, prepared and not sent

Nothing in this directory has been mailed. Robin reviews it and sends it
himself.

## Base

linux-next tag `next-20261016`, commit `2efb7a11f1aa4d2dc285fe2680cca22cb9f72f64`
("Add linux-next specific files for 20261016"). That was the newest
`next-YYYYMMDD` tag on 18 Oct 2026.

v4 (`https://lore.kernel.org/r/20260820-submit-qcom-smbx-send-v1-v4-0-818dabb2771e@snyders.xyz`)
applies on that tag with `git am` and no textual conflicts. The five
prerequisite fixes are already in the tree, so v5 drops the
`prerequisite-patch-id` records.

Power-supply for-next commits now in this base:

- `2f0dec120078` include base when petting watchdog
- `68f645192f64` test battery health status bits
- `2a26d260e72a` fix float voltage selector
- `a2d7dc538da2` validate battery float voltage
- `2548e4fa576a` notify battery overvoltage recovery

Sebastian Reichel applied these on 9 Sep 2026. The for-next commit timestamps
are 2026-09-10 00:43 +0200. Also already in the base, and left as-is:
Kees Cook's `sizeof(*desc)` change (`6415ce7204af`) and the `%pe` conversion
in `smb_get_iio_chan()` (`8761a4577c4f`).

## Conflicts

No rebase conflicts against `next-20261016`.

Fabricio Akio's "set the charge enable after software control"
(`1fba78714201`, power-supply for-next, committed 2026-10-17 23:26 +0200) is
not in `next-20261016`. v5's SMB2 init sequence writes `CHARGING_ENABLE_CMD`
after `CHGR_CFG2` selects software control, so the driver that results from
this series already has that order. Applying v5 on top of `1fba78714201` will
conflict in `smb2_init_seq` because both edits move the same entry. Keep v5's
sequence.

## Review comments

David Heidelberg, v4 2/2,
https://lore.kernel.org/all/44d4db6f-6b84-4cec-9e85-cb7b437bb7f9@ixit.cz/
and https://lore.kernel.org/all/b5f87468-20f1-437f-8610-518df679ee99@ixit.cz/.

- Split `smb_map_charge_status()` into `smb2_map_charge_status()` and
  `smb5_map_charge_status()`. `chip->data->map_charge_status()` calls the
  one stored in the parameter block.
- Removed `smb_get_prop_health()`. `POWER_SUPPLY_PROP_HEALTH` calls
  `chip->data->get_prop_health()` directly.
- PM660 no longer has its own copy of the PMI8998 numbers. Both compatibles
  point at `smb2_data`. A small `smb_match` wrapper holds the power-supply name, so PM660 still
  registers as `pm660-charger` while using the shared `smb2_data` block.
  C cannot override one field of a const object.
- `smb_init_hw()` uses `for (int i = 0; i < len; i++)`. The older retry loop
  in `smb_status_change_work()` was left alone; that loop was not part of
  the review.
- The copied `gen`, `icl_*` and `usbin_current_scale` fields are gone.
  Callers use `chip->data->gen` and the other fields on `chip->data`. The
  struct is `smb_data`; the chip member is `data`.

Cc request (https://lore.kernel.org/all/acdcc316-231c-4683-9624-8141f1a302ef@ixit.cz/):
David Heidelberg `<david@ixit.cz>` and `phone-devel@vger.kernel.org` are on
every message, in addition to the v4 recipient list. `scripts/get_maintainer.pl`
on this shallow tree (no file history) returns Casey Connolly, Sebastian
Reichel, Rob Herring, Krzysztof Kozlowski, Conor Dooley, linux-arm-msm,
linux-pm, devicetree and linux-kernel. Dmitry Baryshkov, Konrad Dybcio,
Krzysztof's oss.qualcomm.com address and Joel Selvaraj are carried from the
v4 headers, where git-based `get_maintainer` had added them.

## Trailers

Patch 1/2 keeps `Reviewed-by: Krzysztof Kozlowski <krzysztof.kozlowski@oss.qualcomm.com>`.
The binding diff is the v4 diff; `git am` applied it with no change, and
`dt_binding_check` passed.

Patch 2/2 keeps `Tested-by: David Heidelberg <david@ixit.cz> # SMB2 (Pixel 3, Mi 8, OP 6 / 6T)`.
He gave that tag on v4, for SMB2 devices, on 16 Sep 2026. v5 changes the
dispatch he asked for and also moves the SMB2 charge-enable write. SMB2
status, health and limit behaviour is otherwise the same. Drop the tag
before sending if you want him to retest first. The cover says the same
thing.

## Build and checkpatch

Host toolchain `aarch64-linux-gnu-gcc`, tree `/tmp/linux-next` at the base
above plus these two commits.

- `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig`
- `CONFIG_CHARGER_QCOM_SMB2=y` (olddefconfig also enables `SPMI`,
  `MFD_SPMI_PMIC` and `IIO`)
- `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- drivers/power/supply/`
  completed cleanly, including `drivers/power/supply/qcom_smbx.o`
- `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- W=1 drivers/power/supply/qcom_smbx.o`
  completed with no warning
- `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- DT_SCHEMA_FILES=Documentation/devicetree/bindings/power/supply/qcom,pmi8998-charger.yaml dt_binding_check`
  completed (`qcom,pmi8998-charger.example.dtb` built)
- `scripts/checkpatch.pl --strict` on both patch files: 0 errors, 0 warnings,
  0 checks
- `git diff --check` on the driver diff: clean

v5 was not booted on the OnePlus 7T Pro. The cover says that. The v4
hardware results are described as v4 results.

## Send, when you are ready

Do not send this until you have read it. The three files already carry
`To:`, `Cc:`, `In-Reply-To` and `References`. The Message-IDs
(`20261018-qcom-smbx-smb5-v5-{0,1,2}@snyders.xyz`) are local placeholders.
`git send-email` will use them as the public ids. That is fine; `b4` will
assign new ones if you import the series into a prep branch instead.

```sh
git send-email --dry-run --confirm=always \
  upstream/smb5-v5/v5-0000-cover-letter.patch \
  upstream/smb5-v5/v5-0001-dt-bindings-power-supply-qcom-pmi8998-charger-add.patch \
  upstream/smb5-v5/v5-0002-power-supply-qcom_smbx-add-SMB5-support.patch
```

Drop `--dry-run` only for the real send. The cover replies to
`<20260820-submit-qcom-smbx-send-v1-v4-0-818dabb2771e@snyders.xyz>`.

Recipients already on the messages:

To:

- Casey Connolly `<casey.connolly@linaro.org>`
- Sebastian Reichel `<sre@kernel.org>`
- Rob Herring `<robh@kernel.org>`
- Krzysztof Kozlowski `<krzk+dt@kernel.org>`
- Conor Dooley `<conor+dt@kernel.org>`

Cc:

- Robin Snyders `<robin@snyders.xyz>`
- `linux-arm-msm@vger.kernel.org`
- `linux-pm@vger.kernel.org`
- `devicetree@vger.kernel.org`
- `linux-kernel@vger.kernel.org`
- Dmitry Baryshkov `<dmitry.baryshkov@oss.qualcomm.com>`
- Konrad Dybcio `<konrad.dybcio@oss.qualcomm.com>`
- Krzysztof Kozlowski `<krzysztof.kozlowski@oss.qualcomm.com>`
- Joel Selvaraj `<foss@joelselvaraj.com>`
- David Heidelberg `<david@ixit.cz>`
- `phone-devel@vger.kernel.org`
