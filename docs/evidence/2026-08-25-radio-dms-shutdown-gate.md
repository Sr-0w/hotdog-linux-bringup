# Read-only DMS shutdown gate

`hotdog-radio-bootstrap-0.9-r0` added a typed DMS Get Operating Mode probe. It
was validated with no SIM and with ModemManager fully stopped and blocked from
D-Bus activation. No Set Operating Mode request was sent.

## Package identity

| Package | SHA-256 |
|---|---|
| `hotdog-radio-bootstrap-0.9-r0.apk` | `6a65cab8cf982464b76fad8c38acdb270f02090325207aa7e2aba826d671834a` |
| `hotdog-radio-bootstrap-openrc-0.9-r0.apk` | `2683348eb4bc47af9bae80cefdaf0a1ac1a70783a98377880ca5d71786a2dcb3` |

The installed daemon SHA256 is
`4530164133199824fbedf48fa3fd8138ccb84b5c597039c7de8a326acbfe4991`.
The service remained disabled.

## Result

Five bounded daemon probes over twelve seconds all returned:

```text
dms-operating-mode=shutting-down
rproc=running
```

An independent upstream qmicli request confirmed the same value:

```text
[qrtr://0] Operating mode retrieved:
    Mode: 'shutting-down'
    HW restricted: 'no'
```

QRTR still exposed DMS, UIM, PDC, NAS, WDS, WMS, Voice, DPM and the other MPSS
services. ModemManager remained absent and remoteproc1 remained `running`.
Therefore `shutting-down` is a stable radio operating mode on this firmware,
not evidence that the MPSS remote processor is gone.

Earlier guarded evidence already established the dangerous transition: with a
PIN-locked card and no active software MCFG, `Set Operating Mode = online`
succeeded, then MPSS asserted in `RFLM@qsf_hl_seq.c`. The PIN merely caused the
generic userspace to request Online; it was not the direct trigger.

The private daemon, repeated-probe and final-qmicli logs have SHA256
`2a668ec35e58dec356af6ee6624057385cbdb4b27fe3795de18928581f583aeb`,
`98cf1831af8d856e8d1b045fff29a441fead02c29041cddd3c6063d86fed73` and
`54c1dd10f7206d3a96af89843bce877e8b9d6cf3e01b08ef1bdd465a3b24d459`.

## Verdict

The pre-online owner must intentionally preserve `shutting-down` while it
discovers UIM, loads/selects/activates MCFG and verifies every active ID. Only
that verified state may issue Set Online. The current daemon exposes the Online
request builder for offline tests but does not call it at runtime.
