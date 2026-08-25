# Read-only resident PDC catalog inventory

`hotdog-radio-bootstrap-0.10-r0` added a bounded software PDC List Configs
probe. It was run with no SIM, ModemManager absent and MPSS in its stable
pre-online state. No PDC config was loaded, selected, activated, deactivated or
deleted.

## Package identity

| Package | SHA-256 |
|---|---|
| `hotdog-radio-bootstrap-0.10-r0.apk` | `70278134224172bf23a1e748aa20e8fd647750c4e828f99e42fb4b945b1acbe0` |
| `hotdog-radio-bootstrap-openrc-0.10-r0.apk` | `d01e39094ab031443014df07a0b6acaad4fcf38392455f95148eb96239926de0` |

The installed daemon SHA256 is
`c72c2a602bef0d836aa1a01374faf4bcb2b747b05d70684c88dfa266cafb0c21`.

## Result

The modem EFS contains 25 unique software configuration IDs. Get Selected still
returns `NotProvisioned`, so none is active or pending. Every ID was compared
byte-for-byte with two independently parsed firmware catalogs:

| Catalog | Parsed profiles | Resident matches |
|---|---:|---:|
| Matching HD1913 OOS10.0.13 | 69 | 0 |
| EU OOS12 F.22 cross-check | 242 | 0 |

Earlier qmicli Config Info evidence named these residents and showed versions,
including `Proximus_VoLTE` version `0x08019809`. The matching OOS10 runtime
profile is instead `Proximus_Belgium` version `0x08013f02` with a different
SHA-1 ID. The 25 residents therefore belong to an older loaded catalog state,
not to the MCFG tree paired with the current MPSS. The F.22 comparison also
shows that they are not interchangeable with an arbitrary later OOS12 update.

The raw probe, sanitized catalog match and final postcheck logs have SHA256
`12f5f21d9eb66d8ac38d49a146843f25368efc56c8b60b3ecb5ea0446b6ba782`,
`99b266f7bda00635d20925d2cc7ff57da5f0ec357d9ebd3da093194fb2d2bf7e`
and `4325581a731be159bfeeeacb8677c72a97be51fba6d2854dbb1c76252669bbb9`.
Temporary APKs were removed, ModemManager remained absent and MPSS remained
`running`.

## Verdict

The final transaction cannot treat resident PDC entries as proof that the
matching profile is already loaded. It must preserve any active or pending ID,
load the selected OOS10 MBN by its exact SHA-1, then set/activate/verify it on
the same subscription. Only after that commit may it delete unmatched inactive
residents. The cleanup plan remains offline-only until those safety conditions
and rollback are covered by replay.
