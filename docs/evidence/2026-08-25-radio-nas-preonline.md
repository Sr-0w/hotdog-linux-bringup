# Read-only NAS pre-online baseline

`hotdog-radio-bootstrap-0.11-r0` added a bounded NAS Get Serving System probe.
It was run without a SIM, with ModemManager absent, DMS in its stable
`shutting-down` mode and no PDC selection. No registration, attach or system
selection request was sent.

## Package identity

| Package | SHA-256 |
|---|---|
| `hotdog-radio-bootstrap-0.11-r0.apk` | `86b143742d9a465408349548d068771ee919a3c3408b87db360b9f1b82eea8b8` |
| `hotdog-radio-bootstrap-openrc-0.11-r0.apk` | `aa86308d2648b70a975720b209e60e02771d85af0709fb25323f8707df25cb90` |

The installed daemon SHA256 is
`d8dc1766030f4e8daf02af5c4bb38dfb11385962b0d295c3472e93b494f85bee`.

## Result

The daemon returned:

```text
nas=registration:not-registered-searching cs:detached ps:detached network:unknown interfaces:1 roaming:unknown
nas-interface0=none
probe_rc=0
```

Independent upstream qmicli output matched every field and additionally
reported zero data-service capabilities and detailed service status `none`.
MPSS remained `running`, ModemManager remained absent and temporary APKs were
removed.

The private probe and postcheck logs have SHA256
`2e52085e606178c6758e8d2227ffaf66053ce2b6bad54ad052e9a1e71e6e6a2c`
and `d65a2bbec469d1f447f22878743a60552f0d753621826f91c45390b42b6c38f1`.

## Verdict

`not-registered-searching` is not sufficient readiness. Registration requires
the registered state; packet data additionally requires PS attached and a real
radio interface. The future DMS Online transition must therefore be followed
by NAS registration/attach confirmation before ModemManager, WDS or any user
data request is released.
