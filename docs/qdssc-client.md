# QDSSC client helper

`helpers/qdssc-client.py` talks to Qualcomm QDSSC QMI service 51 over QRTR.
Its default mode is read-only and sends only `GET_SWT` plus `GET_ENTITY`
queries for `tds`, `ulog`, `prof` and `diag`.

Mutating modes require exactly one explicit QDSSC `--instance` and exactly one
matching QRTR endpoint. Do not rely on an implicit or ambiguous instance while
a phone is shared with other work.

## Safety contract

- Hold the phone lease before any `--enable` or `--disable` run.
- Keep captured traces private unless they have been reviewed; they can expose
  device-specific firmware state or workload details.
- Prepare and verify an AP trace sink before `--enable`. Enabling QDSSC without
  a sink is not a useful capture procedure.
- After a capture, run `--disable --instance <id>` for every enabled instance
  before releasing the lease. If instances `8` and `12` both need a capture,
  perform them as separate enable/capture/disable operations, not one combined
  mutating invocation.

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

The parser is intentionally strict for all expected QMI responses: the QMI
header length must match the received packet exactly, TLVs must be complete,
and the result TLV must be present with exactly the 4-byte result/error
payload. Malformed responses keep the process result nonzero even if the final
GET state appears safe.
