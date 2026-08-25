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

`modemmanager-1.25.95_git20260709-r4` rewrites the system-bus activation
entry to `Exec=/bin/false`. OpenRC remains the only daemon start path.

| Package | SHA-256 |
|---|---|
| `modemmanager-1.25.95_git20260709-r4.apk` | `8d104e104f8a8fd3afb14377b16d1ce57beca390a76071f627d8635d7c78cfd1` |
| `modemmanager-openrc-1.25.95_git20260709-r4.apk` | `9370806b733c1a40a909d417c84c838af2617e7492db49ee432b2534770778c7` |

The APORT also drops its own exact-version `libmm-glib` from build
dependencies, removing the circular dependency that otherwise made every new
`pkgrel` impossible to build. Runtime split-package dependencies remain exact.

`device-oneplus-hotdog-nonfree-firmware-3-r31` SHA256
`950e6553e0567bdbc8ca393e93dd726f50fba15f6259a8e19659e35e111deb8f`
depends on the radio bootstrap packages and removes ModemManager from both boot
and default runlevels. `hotdog-radio-bootstrap-openrc-0.16-r0` repeats that
policy after Plasma's generic post-install and enables only the read-only
bootstrap at boot. The clean Alpha 4 rootfs confirms that final ordering.

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
