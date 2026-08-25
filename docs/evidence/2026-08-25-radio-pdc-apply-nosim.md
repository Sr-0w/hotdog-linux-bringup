# PDC apply no-SIM fail-closed validation

`hotdog-radio-bootstrap-0.12-r0` is the first package containing the complete
approved PDC apply path: runtime gate, secure profile reopen, transactional
executor, typed dispatcher, asynchronous backend and QRTR reconnect controller.
It was exercised without a SIM using a deliberately nonexistent approval path.

## Package identity

| Package | SHA-256 |
|---|---|
| `hotdog-radio-bootstrap-0.12-r0.apk` | `a1a6f56dda0ca70613047bc5b33bc60d2e009b43c9adde02c9a2cc77b9189b06` |
| `hotdog-radio-bootstrap-openrc-0.12-r0.apk` | `017c8e4294275e87a7c958f70fafdf30a0e81f4f72759d8964bdadd76c1c8dc7` |

The installed daemon SHA256 is
`12ae29e7bf2b659b505558408f7609d4743c0aa47e6152787c52eb7d3a96483c`.

## Negative execution gate

The exact mode was:

```sh
hotdog-radio-bootstrapd \
  --apply-pdc=/tmp/does-not-exist \
  --mcfg-root=/usr/share/hotdog-radio/mcfg/mcfg_sw
```

The daemon completed the two read-only UIM views and refused before reading the
approval or allocating the PDC mutation controller:

```text
slots=2 gw_sessions=0 onex_sessions=0 isim_sessions=0
slot1=error apps=0 error=3 physical=0 active=1 logical=1 iccid=absent length=0
slot2=error apps=0 error=3 physical=0 active=1 logical=2 iccid=absent length=0
PDC planning requires a populated GW application
apply_rc=1
```

A post-failure read-only inventory still found exactly 25 resident configs.
DMS remained `shutting-down`, MPSS remained `running`, ModemManager remained
absent and no `/run/hotdog-radio/readiness` appeared. Temporary APKs were
removed.

The private probe and postcheck logs have SHA256
`9068f5f0360624849367fb7f71690b0b4852a400659772db9a3bb0ffaf0091da`
and `c8635cc32afd6fcf5757f5fdb29e3e15404900d5c74bd34d4d56f2948e2a3a7c`.

## Verdict

The packaged execution path is linked and present on target, but remains
inert without a real populated UIM identity. The next SIM-bearing run must first
use dry-run mode to generate/review exact selected IDs and a boot-bound approval;
apply remains forbidden until that evidence exists.
