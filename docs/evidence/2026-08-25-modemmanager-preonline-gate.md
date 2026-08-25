# ModemManager pre-online activation gate

## Problem

Removing ModemManager from the OpenRC runlevel was not sufficient. A Plasma or
other system-bus query immediately recreated `/usr/sbin/ModemManager` through
`org.freedesktop.ModemManager1.service`, even while OpenRC reported the service
stopped. That bypass let ModemManager reach DMS/UIM before the Hotdog PDC/MCFG
bootstrap and could reproduce the post-PIN modem restart.

The installed D-Bus service file already explained that non-systemd systems
should use `Exec=/bin/false`, but the generated package contained
`Exec=/usr/sbin/ModemManager`.

## Package correction

`modemmanager-1.25.95_git20260709-r3` now rewrites the system-bus activation
entry to `Exec=/bin/false`. OpenRC remains the only daemon start path.

| Package | SHA-256 |
|---|---|
| `modemmanager-1.25.95_git20260709-r3.apk` | `0e2cb572d678d12a4ca403999b74eb6b572e3c05068d4777473e1d69aabb2057` |
| `libmm-glib-1.25.95_git20260709-r3.apk` | `a5f513720400f88fed8247b6cf2b386e978f8984a4e0fe2123e554f205ef4c2c` |
| `modemmanager-lang-1.25.95_git20260709-r3.apk` | `65dc8a1197cb83f4991ddccbc70217a3293ed6e267ed267c586e9b32af368f68` |
| `modemmanager-openrc-1.25.95_git20260709-r3.apk` | `21fba0ec1c3471327e18941ecc21ca18087bcf5cc7619159ded4562cd8f59502` |
| `modemmanager-udev-1.25.95_git20260709-r3.apk` | `4d24e3552c28dd9618e3508ced56c3fed4cc4aa32583fbd0a3bec09a788aecb4` |

The APORT also drops its own exact-version `libmm-glib` from build
dependencies, removing the circular dependency that otherwise made every new
`pkgrel` impossible to build. Runtime split-package dependencies remain exact.

`device-oneplus-hotdog-nonfree-firmware-3-r30` SHA256
`b94c472557d17078cf9278a8314c28363eef5159c3b5c26ef4bf8898cfc56e3b`
depends on the radio bootstrap packages and removes ModemManager from both boot
and default runlevels. It does not enable the bootstrap automatically while
the PDC mutation path is still incomplete.

## Hardware validation

The corrected ModemManager packages were installed explicitly on the no-SIM
mainline phone. The prior D-Bus-created daemon was terminated, then `mmcli -L`
was used to exercise activation:

```text
Exec=/bin/false
error: couldn't find the ModemManager process in the bus
mmcli_rc=1
modemmanager-process=absent
```

OpenRC remained stopped, no ModemManager runlevel entry remained, and MPSS
remained `running`. Temporary APKs were removed. The private validation and
postcheck logs have SHA256
`906e6e39da8dc0c740a87d06288497a75fc1eb2851edf266f4532e1e2105ea33`
and `ad54d41fb1ee64732463e382d16ad3e7515929970ecb4562f675451ad5b779b9`.

## Verdict

ModemManager can no longer race the pre-online owner through OpenRC or D-Bus.
When the SIM returns, UIM/PDC planning can run without Plasma silently starting
the generic daemon. ModemManager must only be started explicitly after the
readiness record proves the active MCFG for every populated subscription.
