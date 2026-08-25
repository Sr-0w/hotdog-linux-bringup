# OxygenOS MCFG catalog reconstruction

## Scope

This record identifies the software modem configurations used by OxygenOS and
packages the catalog needed by the mainline radio bootstrap. No proprietary MBN
is tracked in Git. All paths below are firmware-internal paths or public package
destinations.

## Matching OxygenOS 10 source

The runtime MPSS source remains the European HD1913 OxygenOS 10.0.13
`NON-HLOS.bin`:

- source SHA256:
  `7920f87d8544d17efbe93ec9d7365190a43016eb9d286b1361de5fc96ca6a7b9`;
- MPSS build:
  `MPSS.HE.1.0.c11.1-00007-SM8150_GEN_PACK-2.320290.2.328393.1`;
- squashed `modem.mbn` SHA256:
  `559a517c2d4ca5c22d25e0a9b3383bbf7591a632f688b629a19c3e51e3dba9e5`.

The FAT16 image also contains `image/modem_pr/mcfg/configs/mcfg_sw`.
Its `mbn_sw.txt` names 69 software profiles. The tree contains 69
`mcfg_sw.mbn` files, 69 matching `mcfg_sw.sig` files and five list/digest
files. Every MBN passes the clean-room trailer parser.

The Belgian profile in this matching catalog is:

```text
mcfg_sw/generic/eu/proximus/commerci/belgium/mcfg_sw.mbn
carrier=Proximus_Belgium
iin[0]=893200
plmn[0]=206-1
qc_version=0x08013f02
capability=0x00000014
```

## OxygenOS 12 cross-check

A separately obtained OnePlus 7T Pro firmware bundle was used as a second
source of truth:

- outer bundle SHA256:
  `0aee231f1f96f70c0e47f0d5a9d234fdfa1ab41d8ed2c8db76b00e968554b465`;
- EU OOS12 F.22 inner firmware ZIP SHA256:
  `6fff4607d70e5280cfc977c4ccfaa42c31c47a59a6b54ae9cbb6d6b6020b6c10`;
- EU OOS12 `modem.img` SHA256:
  `a0bd9de273fc8145ee51b1f23a2bc39f547dfc8d148072263400f444439aa3ae`.

That newer FAT16 image has 242 unique software profiles. It retains Belgium
and Proximus under the expanded OPPO tree:

```text
mcfg_sw/generic/OPPO_EXP/Belgium/Commercial/Proximus/mcfg_sw.mbn
carrier=Proximus_VoLTE
plmn[0]=206-1
```

This confirms that the carrier configuration did not disappear in later
OxygenOS; the catalog layout changed. The OOS12 profiles are evidence only and
are not mixed with the OOS10 MPSS runtime.

## Mainline consequence

The previous private modem APK installed only the squashed MPSS image. The
running mainline phone therefore had no MCFG files in its root filesystem, and
the read-only PDC query returned `NotProvisioned`. OxygenOS instead reads the
catalog, loads a selected MBN through PDC, sets it on the matching software
subscription, activates all pending subscriptions and verifies the active IDs
before transitioning DMS online.

`scripts/stage-private-modem-firmware.sh` now extracts and validates the MCFG
tree from the same hash-gated OOS10 source. It creates a deterministic private
archive:

- `mcfg-oos10.0.13.tar.gz` size: 1978176 bytes;
- SHA256:
  `a81d9d110cd2aa9ecc906ec69c1698aaf4518142f890fa6f6d8e656e498ff1fa`.

`firmware-oneplus-hotdog-modem-oos10-1.0.11.1.7-r2` installs the catalog under
`/usr/share/hotdog-radio/mcfg/mcfg_sw`. The APK SHA256 from the local package
build is `45ec366a2a850f41be10d3a447dbf175726e57e568a62ceebaacbab035a5cf9e`.
Installing this package alone does not mutate PDC. Load, selection, activation,
verification and rollback remain explicit gated daemon phases.

## Verdict

The missing pre-online MCFG phase is now a concrete implementation gap rather
than an unexplained post-PIN crash. The matching OOS10 catalog is reproducibly
packaged, while the daemon remains read-only until its PDC transaction and
rollback paths are complete and offline-tested.
