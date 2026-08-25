# Read-only UIM and PDC bootstrap validation

The first packaged `hotdog-radio-bootstrap` transport slice was validated on
the mainline phone with no SIM inserted. No PIN, PDC Set/Activate/Deactivate,
DMS state, remoteproc state or phone partition was changed.

## Package identity

| Package | SHA-256 |
|---|---|
| `hotdog-radio-bootstrap-0.5-r0.apk` | `091da530c9e560b90790f610f7eef5942596aa7abec2ffed6af1cbcd46a3baee` |
| `hotdog-radio-bootstrap-openrc-0.5-r0.apk` | `7f43de159e52c8075f817bcf191ff12c3de0d5a9cf94f4720f53071dc6478cd9` |

The APKs were installed from explicit local paths with `apk --no-network` and
no general upgrade. The OpenRC service remained disabled.

## Result

QDSSC/PDC service 36 version 1 instance 0 was present on QRTR node 0. UIM
reported both physical slots as `no-atr-received`, with no provisioning session,
which is the expected no-card behavior of this firmware. An explicit read-only
probe of PDC software subscription 0 then returned:

```text
slots=2 gw_sessions=0 onex_sessions=0 isim_sessions=0
slot1=error apps=0 error=3
slot2=error apps=0 error=3
pdc-sub0=active:- pending:- result:NotProvisioned
bootstrap_rc=0
```

`NotProvisioned` is QMI protocol result 16. It matches the earlier stock qmicli
observation that the modem has resident MCFG software files but no selected or
active software config. The transport now represents that as empty PDC state,
not as a transport failure, so the future selection planner can proceed while
the online gate remains closed.

Both UIM and PDC CIDs were released without libqmi warnings. MPSS remained
running after the probe. The private host log has SHA-256
`29c4bc6866509d6daa491f605bfca8cf5494a270935f6da2c61f11e38f72c415`.
