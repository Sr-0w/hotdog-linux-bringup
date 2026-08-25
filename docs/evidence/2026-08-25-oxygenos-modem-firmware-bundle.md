# OxygenOS 11/12 modem firmware bundle inventory

The user-supplied OnePlus 7T Pro firmware bundle was inventoried without
extracting any proprietary payload into Git. The public helper opens each
nested firmware ZIP, hashes `firmware-update/modem.img`, asks 7-Zip for the FAT
file listing and records only MCFG path statistics.

## Bundle identity

- size: 1045269095 bytes;
- SHA256:
  `0aee231f1f96f70c0e47f0d5a9d234fdfa1ab41d8ed2c8db76b00e968554b465`;
- generated JSON SHA256:
  `6c559f66c0e811616d3156b3a9cc72cca0370efb13db9ca760388d8e8f250459`.

## Firmware matrix

| Release/region | Inner ZIP SHA256 | `modem.img` SHA256 | MCFG profiles | Signatures |
|---|---|---|---:|---:|
| OOS11.0.9.1 EU | `7514c7e963827c85c90fdb39e3db0309e1507c41b49824544b81ac76b32fc573` | `53164f24c67a4c4f76f274a369c3fd53fa3273382e9b000069d336a1b1ee2fad` | 75 | 75 |
| OOS11.0.9.1 IN | `3e026af3441dffc1f83f17567f56231b0f55e3cd2ef52a7bf0c197ec8e92c1c4` | `9dce302e0b8b30b1defcf21cf2b9d06da48658fc523e992b97f53d87eefb1987` | 75 | 75 |
| OOS11.0.9.1 NA | `ffe364069c835d528366620d9ee4c23c48c0495455f3ec55799365eddd445f2d` | `9dce302e0b8b30b1defcf21cf2b9d06da48658fc523e992b97f53d87eefb1987` | 75 | 75 |
| OOS12 F.22 EU | `6fff4607d70e5280cfc977c4ccfaa42c31c47a59a6b54ae9cbb6d6b6020b6c10` | `a0bd9de273fc8145ee51b1f23a2bc39f547dfc8d148072263400f444439aa3ae` | 242 unique | 0 |
| OOS12 F.22 IN | `f1682f348a41eff0a0e5824c8f90c4edc316d6be8426997c78ff0c241fe92f9c` | `a0bd9de273fc8145ee51b1f23a2bc39f547dfc8d148072263400f444439aa3ae` | 242 unique | 0 |
| OOS12 F.22 NA | `9c5481f25cf985455c10099c85b46f9e9930211a0e3357dd1484e720261e9a73` | `a0bd9de273fc8145ee51b1f23a2bc39f547dfc8d148072263400f444439aa3ae` | 242 unique | 0 |

OOS11 EU uses a different modem image from the identical IN/NA pair, even
though all three expose the same profile count and signature layout. OOS12 uses
one identical modem image across all three regions, expands the catalog from 75
to 242 unique paths and no longer carries separate `mcfg_sw.sig` files. Its FAT
listing repeats one default path three times; the inventory reports 244 listed
entries, 242 case-folded unique paths and one duplicate group.

## Consequence

An “OOS11” or “OOS12” label is not sufficient provenance for MPSS or MCFG.
Runtime pairing must use exact image and catalog hashes plus region. The current
mainline runtime deliberately remains on the matching HD1913 OOS10.0.13 pair;
the OOS11/OOS12 matrix is reverse-engineering evidence, not a source of profiles
to mix into that runtime.

Reproduction:

```sh
scripts/inventory-oxygenos-modem-firmware.py /private/oneplus-firmware-bundle.zip \
  --output /private/evidence/modem-firmware-inventory.json
```
