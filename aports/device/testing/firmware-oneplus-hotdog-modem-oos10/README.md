# Private OxygenOS 10 modem firmware source

This package installs the OxygenOS 10.0.13 EU modem image that matches the
Hotdog baseline used for the stock DTBO, persist data and sensor firmware:

- source image: `NON-HLOS.bin` from OxygenOS 10.0.13 HD1913;
- source SHA256: `7920f87d8544d17efbe93ec9d7365190a43016eb9d286b1361de5fc96ca6a7b9`;
- modem build: `MPSS.HE.1.0.c11.1-00007-SM8150_GEN_PACK-2.320290.2.328393.1`;
- squashed size: 75953080 bytes;
- squashed SHA256: `559a517c2d4ca5c22d25e0a9b3383bbf7591a632f688b629a19c3e51e3dba9e5`.
- software MCFG catalog: 69 profiles and 69 matching signatures from the same
  FAT image;
- deterministic MCFG archive size: 1978176 bytes;
- deterministic MCFG archive SHA256:
  `a81d9d110cd2aa9ecc906ec69c1698aaf4518142f890fa6f6d8e656e498ff1fa`.

The proprietary source and squashed image are excluded from Git. Run
`scripts/stage-private-modem-firmware.sh` with the lawfully obtained OOS10
`NON-HLOS.bin` before building this APK. The package installs the catalog under
`/usr/share/hotdog-radio/mcfg/mcfg_sw`; it does not select, load or activate a
profile by itself.

This catalog is part of the modem boot contract. OxygenOS reads `mbn_sw.txt`,
loads the selected MBN through PDC, then sets and activates it per subscription
before putting DMS online. Shipping only the squashed MPSS image leaves PDC in
`NotProvisioned`, which is the read-only state observed on mainline before this
catalog was packaged.

The public firmware package previously supplied an exact OOS12 modem image,
`MPSS.HE.1.0.c10-00093-SM8150_GEN_PACK-1.505508.2.505991.36`. Its squash is
byte-identical to the currently published `modem.mbn`, SHA256
`de2ae2cf307cd8d719bd3b65579240bfeac0ae81ec817a825f2f1fa7bd737ecd`.
This alternative exists to avoid mixing that OOS12 MPSS with the OOS10
low-level baseline after a reproducible RFLM/QLINK watchdog during SIM radio
bring-up.
