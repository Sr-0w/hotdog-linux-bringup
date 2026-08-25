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

`modemmanager-1.25.95_git20260709-r8` rewrites the system-bus activation
entry to `Exec=/bin/false`. OpenRC remains the only daemon start path.

| Package | SHA-256 |
|---|---|
| `modemmanager-1.25.95_git20260709-r8.apk` | `3825a4bf5fdfaada6f793e1c90c8498eb025c215273c45b366c6713ed45a7354` |
| `modemmanager-openrc-1.25.95_git20260709-r8.apk` | `e1a0b464e7f3ce7174069abc9dbc048eeb7a782c0ad044de45f57e1613e7a392` |

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

Revision `r8` adds the OxygenOS-proven QMI Voice IP Dial tuple. Registered,
available IMS voice on the current primary slot selects `VOICE_IP`, audio
attributes `TX|RX` and video attributes zero. Limited or invalid IMS state
retains the existing automatic/CS Dial. This is signaling-domain selection,
not a claim that the IMS bearer, Q6 call route or RTP media is already working.

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
