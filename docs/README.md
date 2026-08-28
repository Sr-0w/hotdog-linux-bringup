# Documentation

Last reviewed: 2026-08-25

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
- [Markdown audit](markdown-audit-2026-08-25.md): exhaustive file-by-file
  review register, checked by CI.

## Focused technical records

- [Camera port plan](camera-port-plan.md)
- [Android/OxygenOS reference policy](android-reference.md)
- [Evidence archive and supersession policy](evidence/README.md)

Recent evidence and current regression records:

- [OxygenOS F.22 IN/EU and LineageOS vbmeta contract](evidence/2026-08-28-oxygenos-f22-in-eu-and-lineage.md)
- [v0.2.0-alpha.1 Linux 6.17 release](release-notes-v0.2.0-alpha.1.md)
- [OxygenOS 12 slot-A install control](evidence/2026-08-28-oos12-slot-a-control.md)
- [Alpha 1 validation](evidence/2026-08-10-v0.1.0-alpha.1.md)
- [Alpha 2 validation and corrected DTBO contract](evidence/2026-08-25-v0.1.0-alpha.2.md)
- [Alpha 3 source-complete replacement](evidence/2026-08-25-v0.1.0-alpha.3.md)
- [Alpha 4 clean current-state rebuild](release-notes-v0.1.0-alpha.4.md)
- [Alpha 5 package-complete runtime rebuild](release-notes-v0.1.0-alpha.5.md)
- [Package-complete kernel, sensors and proximity evidence](evidence/2026-08-25-package-complete-runtime.md)
- [All four cameras and pop-up lifecycle](evidence/2026-08-10-mainline616-camera-imx471-popup.md)
- [GNSS QMI engine](evidence/2026-08-10-gnss-qmi-loc.md)
- [Read-only UIM and subscription-scoped PDC](evidence/2026-08-25-radio-pdc-readonly.md)
- [Read-only UIM physical-slot identity](evidence/2026-08-25-radio-uim-slot-identity.md)
- [OxygenOS MCFG catalog reconstruction](evidence/2026-08-25-oxygenos-mcfg-catalog.md)
- [Installed MCFG catalog and no-SIM dry-run gate](evidence/2026-08-25-radio-mcfg-dry-plan.md)
- [ModemManager pre-online activation gate](evidence/2026-08-25-modemmanager-preonline-gate.md)
- [Read-only DMS shutdown gate](evidence/2026-08-25-radio-dms-shutdown-gate.md)
- [Read-only NAS pre-online baseline](evidence/2026-08-25-radio-nas-preonline.md)
- [Read-only resident PDC catalog](evidence/2026-08-25-radio-pdc-resident-catalog.md)
- [PDC apply no-SIM fail-closed validation](evidence/2026-08-25-radio-pdc-apply-nosim.md)
- [OxygenOS 11/12 modem firmware bundle](evidence/2026-08-25-oxygenos-modem-firmware-bundle.md)
- [NFC reader and bidirectional APDU exchange](evidence/2026-08-10-nfc-nxp-nci.md)
- [SLPI/SSC and isolated QUP-to-EBI1 route failure](evidence/2026-08-10-slpi-sensor-dsp.md)
- [Sensor-PD clock state and island-mode control](evidence/2026-08-20-sensor-pd-clock-and-island-control.md)
- [Haptics](evidence/2026-08-11-haptics-aw8697.md)
- [Upstream review follow-up](evidence/2026-08-12-upstream-follow-up.md)
- [IPA v4.1](evidence/2026-08-12-ipa-v41-scope.md)
- [Dual-channel camera flash](evidence/2026-08-12-camera-flash.md)
- [SMB5 v3 hardware validation](evidence/2026-08-13-smb5-v3-hardware-validation.md)
- [SMB5 v4 dock and VBUS role validation](evidence/2026-08-20-smb5-v4-dock-validation.md)
- [Display regression 01 — transient scanout recovery](evidence/2026-08-20-display-regression-01.md)
- [Writable Hexagon service](evidence/2026-08-13-hexagonrpcd-write.md)

Raw dumps, serials, credentials, complete RAM captures and generated images
remain ignored and local. Only sanitized evidence, reproducible source inputs
and permitted firmware metadata belong in Git.
