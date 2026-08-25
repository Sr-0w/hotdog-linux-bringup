# Read-only UIM physical-slot identity validation

`hotdog-radio-bootstrap-0.6-r0` was validated on the mainline phone with no SIM
inserted. The daemon only issued UIM Get Card Status, UIM Get Slot Status and
PDC Get Selected Config. It did not submit a PIN, load or select an MBN,
activate PDC, change DMS state or restart a subsystem.

## Package identity

| Package | SHA-256 |
|---|---|
| `hotdog-radio-bootstrap-0.6-r0.apk` | `d34c6ca57ebb8bbc35b6bb5c7a2fe33e7590ea4621405d55d921912ea312f22a` |
| `hotdog-radio-bootstrap-openrc-0.6-r0.apk` | `c403257ce89348a183a629718cd8b20dcd5d8db0b249babc278e7e4abb9379ad` |

The installed daemon SHA256 is
`e503991bc7447df54145dd2c0c1cb9763d70bd34ca9444a7b92c96e9e93f0472`.
The APKs were installed from explicit local paths with `apk --no-network`; the
OpenRC service remained disabled.

## Result

The modem exposes two separate physical slots. Both are marked logically active
by the firmware even though neither contains a card:

```text
slots=2 gw_sessions=0 onex_sessions=0 isim_sessions=0
slot1=error apps=0 error=3 physical=0 active=1 logical=1 iccid=absent length=0
slot2=error apps=0 error=3 physical=0 active=1 logical=2 iccid=absent length=0
pdc-sub0=active:- pending:- result:NotProvisioned
bootstrap_rc=0
```

This independently explains the former Plasma/ModemManager single-slot symptom:
the firmware is DSDS and exposes both slots, but choosing the last merely active
slot collapses presentation onto an empty slot. Selection must prefer a
populated active slot while preserving both physical SIM objects.

MPSS remained `running`, all temporary APKs were removed, and no service was
enabled. The private host logs have SHA256
`f8d8f9a490990113df0a1f2b31f8d7e9553aa30c0e4fd40b4191d0e8845b8bcd`
and `170a303a2dd085f5016c43fc8611c4f1c2d29354f6b28c9bf480df581523160d`.

## Verdict

The dual-slot UIM identity layer is hardware-validated for the no-card state.
A future SIM run can now join the ICCID to the correct physical slot before
MCFG planning and before any PIN operation. It must still preserve retry counts
and remain behind the PDC readiness gate.
