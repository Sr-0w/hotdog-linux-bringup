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

`modemmanager-1.25.95_git20260709-r7` rewrites the system-bus activation
entry to `Exec=/bin/false`. OpenRC remains the only daemon start path.

| Package | SHA-256 |
|---|---|
| `modemmanager-1.25.95_git20260709-r7.apk` | `30f4c3b72072b00aa08a4e4c00392d749746fe30ba11b00766a3932a6f0950b1` |
| `modemmanager-openrc-1.25.95_git20260709-r7.apk` | `6449e03412c4555c9ea7d4407f8253aedb7b97619fdbcb3a9ca9238fea07cc8f` |

The APORT also drops its own exact-version `libmm-glib` from build
dependencies, removing the circular dependency that otherwise made every new
`pkgrel` impossible to build. Runtime split-package dependencies remain exact.

Revision `r5` also fixes the standard QMI Voice D-Bus surface. All Call Status
no longer requires the optional Remote Party Number TLV, so a restricted or
temporarily numberless call remains visible. A number is copied only for
allowed/payphone presentation, and OTAPA, non-standard OTASP and supplementary
control sessions are filtered before they can appear as Plasma calls.

Revision `r6` adds only an OpenRC soft dependency and ordering constraint on
`hotdog-imsd`. The IMSA owner is not enabled in a boot runlevel and owns no
WDS, WMS or Voice CID. When verified radio readiness exists, it can publish the
per-subscription IMS snapshot before ModemManager starts; when readiness is
revoked, it removes that snapshot and exits while the lifecycle supervisor
stops ModemManager.

Revision `r7` makes the standard QMI messaging owner preserve the WMS transport
domain. For a 3GPP outgoing message, ModemManager reads the strict, boot-bound
IMSA snapshot once for the current 1-based primary SIM slot and sets `SMS on
IMS` consistently on every raw or stored part only when SMS is an available
IMS capability. Missing, stale, malformed, symlinked or writable state falls
back to circuit-switched WMS. Transfer-route indications copy the modem's own
`SMS on IMS` bit into Send Ack. ModemManager still allocates no IMSA CID.

`device-oneplus-hotdog-nonfree-firmware-3-r31` SHA256
`950e6553e0567bdbc8ca393e93dd726f50fba15f6259a8e19659e35e111deb8f`
depends on the radio bootstrap packages and removes ModemManager from both boot
and default runlevels. `hotdog-radio-bootstrap-openrc-0.18-r0` repeats that
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
