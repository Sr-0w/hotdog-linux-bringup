# Guarded post-PIN radio re-attestation

The schema-2 radio readiness record includes each UIM application state. A
successful PIN verification therefore makes a prior `locked` record stale, but
ModemManager cannot authoritatively update it because it does not own the full
PDC/MCFG and DMS attestation.

ModemManager patch `0007-qmi-request-radio-reattest-after-PIN.patch` adds a
single bounded handoff after successful UIM or legacy DMS PIN verification. It
atomically publishes `pin-unlocked` as a 0600 file in the trusted
`/run/hotdog-radio` directory. The PIN, ICCID, IMSI and retry counters are never
written. Failure to publish is logged after the modem success and is not
reported as a PIN failure, so the UI cannot encourage a duplicate attempt.

`hotdog-radio-supervisord` consumes only the exact regular, non-writable,
non-symlink request. It revokes the locked readiness record and stops
ModemManager before clearing its one-shot attestation guard. The existing
boot-bound approval then drives the complete UIM/PDC/DMS bootstrap; ModemManager
is restarted only after new readiness passes boot ID and packaged firmware/MCFG
identity checks. An invalid request blocks the lifecycle instead of bypassing
the gate.

## Offline validation

The seven-patch ModemManager series was applied and cross-built in order for
aarch64 as `1.25.95_git20260709-r9`.

| Artifact | SHA-256 | Size |
| --- | --- | ---: |
| `modemmanager-1.25.95_git20260709-r9.apk` | `315083df4a22caf625722ca9deae606d690206d825d8639a42ca084e91f221a7` | 1,390,149 |
| `modemmanager-openrc-1.25.95_git20260709-r9.apk` | `6ba451ddabdad004606236aebac1a373b6044e178cdc070e2b0dedf7a559dfe3` | 1,711 |
| packaged `/usr/sbin/ModemManager` | `440b3d78065fa2ce9568b1e40599be96beb8deb098ed78fb0ab583e12e0f14ae` | 2,099,136 |

The final patch SHA-512 is
`71f0451070cc434ddf193a785251c6317bbb09dff7f735b882287173c00a0431925be4452ddd7def4d546b445fefbe7d096797303cf1a4c1291e004a65426407`.
The extracted binary retains the success, failure and request markers. Public
tests cover atomic request consumption, one-shot deletion, weak permissions,
symlinks, malformed content, patch checksum and supervisor sequencing.

No SIM/PIN hardware test was performed. The next SIM run must check the retry
counter before and after one PIN attempt, observe the controlled ModemManager
stop/re-attest/restart sequence, and reject any modem or phone crash as failure.
