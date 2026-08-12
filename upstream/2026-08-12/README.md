# Upstream mail archive - 2026-08-12

This directory records the non-NFC upstream follow-up. Files under `*-lore`
and the two `thread.mbx` files are verbatim public mailbox snapshots. The EMLs
under `qcom-smbx-v2` are the inspected pre-send render; the public lore mbox is
authoritative.

| Artifact | Public thread | SHA-256 |
| --- | --- | --- |
| `q6afe-v1-withdrawn/thread.mbx` | withdrawal of `<20260811-submit-q6afe-display-port-v1-1-3bc8f2f38bdf@snyders.xyz>` | `778209b65b56d7b01263912396f25b60ce4feb0245bcb5aa4fe6a0594b7a6b2c` |
| `sm8150-dload-v2/thread.mbx` | `<20260811-submit-sm8150-dload-v2-1-fb688ac4896b@snyders.xyz>` | `e68fb3bb7dd9b596514c283cf87b3fe927aafef5583121f5fd3e1d5aac239fa4` |
| `qcom-smbx-fixes-v1-lore/qcom-smbx-fixes-v1.mbx` | `<20260812-qcom-smbx-fixes-v1-0-eb48246be599@snyders.xyz>` | `de39f8eb003708040bdf25fce4edecabc98a4119fb743d3c4bd44730f70decf5` |
| `qcom-smbx-v2-lore/qcom-smbx-v2.mbx` | `<20260812-submit-qcom-smbx-send-v1-v2-0-f504b8f9bfad@snyders.xyz>` | `472af576c1204effc9d707c5dac63bf28dbdbe51ad90b3b71c3672075fbfe37c` |

The SMB5 lore mbox contains the complete thread, including v1 and its
automated review. Use `b4 am -v2` when extracting only the submitted v2.
