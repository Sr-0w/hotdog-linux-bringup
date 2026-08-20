# QDSSC client helper

`helpers/qdssc-client.py` talks to Qualcomm QDSSC QMI service 51 over QRTR.
Its default mode is read-only and sends only `GET_SWT` plus `GET_ENTITY`
queries for `tds`, `ulog`, `prof` and `diag`.

Mutating modes require an explicit QDSSC `--instance`. Do not rely on an
implicit instance while a phone is shared with other work.

## Safety contract

- Hold the phone lease before any `--enable` or `--disable` run.
- Keep captured traces private unless they have been reviewed; they can expose
  device-specific firmware state or workload details.
- Prepare and verify an AP trace sink before `--enable`. Enabling QDSSC without
  a sink is not a useful capture procedure.
- After a capture, run `--disable --instance <id>` for every enabled instance
  before releasing the lease.

## Ordering contract

Enable uses global software trace first, then detailed entities:

```text
SET_SWT=1 -> SET_ENTITY(tds/ulog/prof/diag)=1 -> final GET state
```

Rollback disables the detailed entities first, then global software trace:

```text
SET_ENTITY(tds/ulog/prof/diag)=0 -> SET_SWT=0 -> final GET state
```

Every QMI response prints the `result` and `error` fields. A firmware error,
including error 94 (`NOT_SUPPORTED`), is reported as a failure and is not
treated as a confirmed rollback.
