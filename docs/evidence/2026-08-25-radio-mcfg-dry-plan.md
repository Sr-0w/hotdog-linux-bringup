# Installed MCFG catalog and no-SIM dry-run gate

The matching OxygenOS 10 MCFG catalog and the non-mutating transaction planner
were validated on the mainline phone without a SIM. No PDC Load, Set Selected,
Activate, Deactivate or Delete request was sent. DMS and remoteproc state were
not changed.

## Installed packages

| Package | SHA-256 |
|---|---|
| `firmware-oneplus-hotdog-modem-oos10-1.0.11.1.7-r2.apk` | `45ec366a2a850f41be10d3a447dbf175726e57e568a62ceebaacbab035a5cf9e` |
| `hotdog-radio-bootstrap-0.8-r0.apk` | `5e01e5dc11558458204c61a6514b9f432347266b24a803cb9437440cf3e75663` |
| `hotdog-radio-bootstrap-openrc-0.8-r0.apk` | `b372bbd662a6b25fd20bdc676f0afa7268ab48f501e90d261df32635a9b1a3ab` |

The firmware upgrade retained the exact running OOS10 `modem.mbn` SHA256
`559a517c2d4ca5c22d25e0a9b3383bbf7591a632f688b629a19c3e51e3dba9e5`.
The installed catalog contains 69 `mcfg_sw.mbn` files, 69 signatures and 143
files in total. The installed daemon SHA256 is
`f5b2fe9b9b5e359421a7d713c91cc5d5eb5287a26f7533a78516331729259e03`.

## Negative planning gate

The exact dry-run request was:

```sh
hotdog-radio-bootstrapd \
  --plan-pdc \
  --mcfg-root=/usr/share/hotdog-radio/mcfg/mcfg_sw
```

It completed both read-only UIM requests, preserved the two empty physical
slots, and then refused before allocating a PDC mutation path:

```text
slots=2 gw_sessions=0 onex_sessions=0 isim_sessions=0
slot1=error apps=0 error=3 physical=0 active=1 logical=1 iccid=absent length=0
slot2=error apps=0 error=3 physical=0 active=1 logical=2 iccid=absent length=0
PDC planning requires a populated GW application
plan_rc=1
```

A separate explicit read-only PDC probe still returned
`active:- pending:- result:NotProvisioned` with rc 0. MPSS remained `running`.
The service was not added to a runlevel and all temporary phone APKs were
removed.

The private host logs have SHA256
`485ec06f1e9b5ee10fbf9493747c8d3a4eb455c486154d68b516b88fa3852b98`
and `725c8b2457f8845671dc379665df1115b4e6e67625d47ba8c98099c842c323bd`.

## Verdict

The MCFG input needed to replace OxygenOS qcrild is now present on the phone,
and the daemon fails closed in the exact no-card state. When a SIM is available,
the next read-only run can join its physical slot and ICCID to the catalog and
print the complete load/select/activate/verify transaction without executing
it.
