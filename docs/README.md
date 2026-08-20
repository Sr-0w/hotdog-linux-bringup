# Documentation

Last reviewed: 2026-08-13

The active path is direct boot from the OnePlus A/B bootloader into the
mainline-oriented Linux 6.16 reference kernel and a normal postmarketOS
userspace. The downstream 4.14/kexec and Linux 6.17 K1 paths are retained only
as recovery and historical evidence. The final target is upstream Hotdog
support shared by postmarketOS and a native Ubuntu Touch/Lomiri port without
Halium.

## Start here

- [Support status](status.md): current evidence-based hardware matrix and the
  exact partial, broken and unsupported gaps.
- [Roadmap](roadmap.md): completed timeline, current checkpoint and the ordered
  path to full upstream Linux, postmarketOS and Ubuntu Touch/Lomiri support.
- [Build and test workflow](build-and-test.md): current package build,
  validation and hardware-test flow.
- [Release installation](release-install.md): public artifact verification,
  installation, recovery and version contract.
- [Device safety](device-safety.md): mandatory A/B, recovery, locking and
  destructive-write safeguards.

## Architecture and history

- [Boot architecture](boot-flow.md): current direct path, distribution boundary
  and historical bridge role.
- [Direct mainline boot](direct-boot.md): accepted direct-boot contract followed
  by the historical D-series investigation.
- [Bring-up history](bringup-history.md): chronological validation narrative
  through the current IPA/NFC/haptics/SLPI/SMB5 frontier.
- [Mainline bring-up fixes](mainline-bringup.md): fixes needed to reach the
  accepted direct path and the remaining upstream cleanup.
- [Hardware enablement roadmap](hardware-roadmap.md): subsystem-level proven
  state, next tests and upstream gates.

## Reproduction and upstreaming

- [Host setup](host-setup.md): tools, source bootstrap, pmbootstrap and local
  device configuration.
- [Artifacts and reproducibility](artifacts.md): current package artifacts,
  hashes and historical diagnostic artifact classes.
- [Source trees](sources.md): authoritative upstreams, vendor references and
  Ubuntu Touch/Lomiri sources.
- [pmaports upstreaming plan](pmaports-upstreaming.md): current blockers,
  package architecture and submission gates.
- [Linux upstream submissions](upstream-submissions.md): patch-series state,
  recipients and review workflow.
- [Repository layout](repository-layout.md): tracked, ignored and local-only
  data boundaries.

## Focused technical records

- [Camera port plan](camera-port-plan.md)
- [Android/OxygenOS reference policy](android-reference.md)
- [Current hardware evidence](evidence/)

Recent evidence that defines the 2026-08-13 checkpoint:

- [Alpha 1 validation](evidence/2026-08-10-v0.1.0-alpha.1.md)
- [All four cameras and pop-up lifecycle](evidence/2026-08-10-mainline616-camera-imx471-popup.md)
- [GNSS QMI engine](evidence/2026-08-10-gnss-qmi-loc.md)
- [NFC reader and bidirectional APDU exchange](evidence/2026-08-10-nfc-nxp-nci.md)
- [SLPI/SSC and isolated QUP-to-EBI1 route failure](evidence/2026-08-10-slpi-sensor-dsp.md)
- [Sensor-PD clock state and island-mode control](evidence/2026-08-20-sensor-pd-clock-and-island-control.md)
- [Haptics](evidence/2026-08-11-haptics-aw8697.md)
- [Upstream review follow-up](evidence/2026-08-12-upstream-follow-up.md)
- [IPA v4.1](evidence/2026-08-12-ipa-v41-scope.md)
- [Dual-channel camera flash](evidence/2026-08-12-camera-flash.md)
- [SMB5 v3 hardware validation](evidence/2026-08-13-smb5-v3-hardware-validation.md)
- [SMB5 v4 dock and VBUS role validation](evidence/2026-08-20-smb5-v4-dock-validation.md)
- [Writable Hexagon service](evidence/2026-08-13-hexagonrpcd-write.md)

Raw dumps, serials, credentials, complete RAM captures and generated images
remain ignored and local. Only sanitized evidence, reproducible source inputs
and permitted firmware metadata belong in Git.
