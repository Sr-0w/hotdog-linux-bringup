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

`modemmanager-1.25.95_git20260709-r5` rewrites the system-bus activation
entry to `Exec=/bin/false`. OpenRC remains the only daemon start path.

| Package | SHA-256 |
|---|---|
| `modemmanager-1.25.95_git20260709-r5.apk` | `97ed25ee6a711130faca5a6d7cf990422b1fa17aca602d81063ff36ff6eeb820` |
| `modemmanager-openrc-1.25.95_git20260709-r5.apk` | `380a202c9b684d13ab8a3892d61652df4c977a4edbb5a2576681bb1efc688d6f` |

The APORT also drops its own exact-version `libmm-glib` from build
dependencies, removing the circular dependency that otherwise made every new
`pkgrel` impossible to build. Runtime split-package dependencies remain exact.

Revision `r5` also fixes the standard QMI Voice D-Bus surface. All Call Status
no longer requires the optional Remote Party Number TLV, so a restricted or
temporarily numberless call remains visible. A number is copied only for
allowed/payphone presentation, and OTAPA, non-standard OTASP and supplementary
control sessions are filtered before they can appear as Plasma calls.

`device-oneplus-hotdog-nonfree-firmware-3-r31` SHA256
`950e6553e0567bdbc8ca393e93dd726f50fba15f6259a8e19659e35e111deb8f`
depends on the radio bootstrap packages and removes ModemManager from both boot
and default runlevels. `hotdog-radio-bootstrap-openrc-0.17-r0` repeats that
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
