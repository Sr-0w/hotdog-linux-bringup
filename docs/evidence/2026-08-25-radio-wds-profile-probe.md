# Subscription-scoped WDS profile probe

`hotdog-radio-bootstrap-0.19-r0` adds a bounded, read-only WDS profile probe
for the two physical Hotdog subscriptions. It is built from public source
commit `24f1e2fdb755b9a4752703471e18c2bfc1d164f0` and installed as
`/usr/libexec/hotdog-wds-profile-probe`.

The probe allocates one WDS CID at a time, binds it to the requested modem
subscription, lists 3GPP profiles and reads only the fields needed to select an
IMS bearer: APN, PDP family, APN-type mask, enabled state and P-CSCF-via-PCO.
It does not request usernames, passwords, ICCIDs or IMSIs. Its source contains
no UIM, Start Network, Stop Network or rmnet-link operation. Releasing each CID
is the only cleanup action.

## Offline build evidence

The package was cross-built in the postmarketOS aarch64 buildroot against
`libqmi 1.39.0` headers and the locally packaged `libqmi
1.38.0_git20260414-r3` ABI. The strict target compile passed with
`-Wall -Wextra -Werror`.

| Artifact | SHA-256 | Size |
| --- | --- | ---: |
| `hotdog-radio-bootstrap-0.19-r0.apk` | `9b97ea71bdb4c5da6743bafc6ccba0100e80014f48befd03b6a5b9a1a13af40d` | 88,579 |
| `hotdog-radio-bootstrap-openrc-0.19-r0.apk` | `79b5cfa87a3c5e2fb84c19ad48f0d601b5bd2a14ca3c0d5d0a4a268ea2b8d9b3` | 2,601 |
| packaged `hotdog-wds-profile-probe` | `6a6252dd57b043fb5e424b5a71f2edbefad473e684587ec06cfffb84c6325fc2` | 67,392 |

The extracted binary is an AArch64 PIE using musl and imports the generated
libqmi Bind Subscription, Get Profile List and Get Profile Settings methods.
The package does not enable a new OpenRC service; execution remains an explicit
diagnostic action so it cannot race ModemManager at every boot.

## No-SIM hardware smoke

The packaged probe was then installed on the running mainline 6.16 Hotdog and
executed once with both physical SIM slots empty. Preflight independently
reported `no-atr-received` for slots 1 and 2, MPSS running, WDS service 1 on
QRTR node 0 and ModemManager stopped.

The probe returned zero. Subscription 0 exposed one profile, rejected as
incomplete; subscription 1 exposed four profiles, three structurally usable.
Neither inventory contained an IMS candidate without a SIM. The different
counts prove that each WDS CID was bound to its requested subscription rather
than reading one global inventory twice.

The boot ID did not change, MPSS remained running, both slots remained empty,
and the network-device set remained exactly `lo rmnet_ipa0 usb0 wlan0`. No probe
process or temporary APK remained after cleanup. This proves QRTR/WDS wiring,
per-subscription profile enumeration and clean CID release without a crash. It
does not prove registration, default data, an IMS data call, SMS or voice.

Private run directory: `logs/2026-08-25-modem-nosim-wds-profile-smoke`.
The authoritative probe log `08-wds-profile-probe-run.txt` has SHA-256
`85a7a929274e3b28005df87d036184d52ce4273ac11b1c243ffe6ef47b495b40`;
the corrected final-state log `11-corrected-final-state.txt` has SHA-256
`0d31f7a7a8d46197319aa7b4d847bc92b435611d524b5129ff3558ea787298b0`.
