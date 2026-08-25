# OnePlus 7T Pro postmarketOS v0.1.0-alpha.4

`v0.1.0-alpha.4` is a clean current-state rebuild for the OnePlus 7T Pro
HD1913 (`hotdog`). It supersedes Alpha 1, Alpha 2 and Alpha 3. Do not reuse or
mix assets from those releases.

Alpha 1 omitted the filtered DTBO that was present on the development phone.
Alpha 2 corrected the artifact set but its source tag missed three libcamera
patches. Alpha 3 corrected that provenance issue, but reused the Alpha 2
payloads. Alpha 4 rebuilds the rootfs and boot image from the current public
tree and packages the complete matching set:

- the fresh postmarketOS nested-GPT system image;
- its matching 100,663,296-byte AVB boot image;
- the required 25,165,824-byte filtered D7 DTBO;
- the matching kernel APK, manifest, checksums and install guide.

## Current-state changes

- Fresh rootfs composition with `device-oneplus-hotdog 3-r30`, the current
  hardware integration and the complete libcamera patch set.
- `hotdog-radio-bootstrap 0.15-r1` contains the guarded UIM/PDC/DMS bootstrap,
  transactional rollback, strict runtime identity checks and readiness handoff.
- `firmware-oneplus-hotdog-modem-oos10 1.0.11.1.7-r3` installs the matching
  OxygenOS 10 MPSS plus the attested 69-profile MCFG catalog.
- `modemmanager 1.25.95_git20260709-r4` includes slot-scoped PIN handling,
  dual-slot selection, disabled D-Bus auto-activation and the correct OpenRC
  `polkit-elogind` provider.
- The image includes the validated USB ACM console, alert slider, haptics,
  Plasma flashlight, NFC reader, SLPI sensor infrastructure, four-camera stack,
  Wi-Fi suspend fix and the existing mainline 6.16 hardware baseline.
- Release tooling now publishes `INSTALL.md` and the DTBO automatically and
  covers `MANIFEST.md` with `SHA256SUMS`.

## Important limitations

The modem pipeline remains fail-closed: no SIM, unapproved MCFG state or failed
readback prevents ModemManager from starting. LTE data, SMS, calls and IMS are
not claimed working by this release. Ultrasonic proximity, UFS ICE, Bluetooth
lifecycle, call/DisplayPort audio, fingerprint, Warp charging and production
camera quality remain incomplete. See [status.md](status.md) for the detailed
evidence-backed matrix.

The release set is offline-validated as an atomic image. It has not yet been
booted as this exact complete set on hardware. Read the attached `INSTALL.md`,
verify every entry in `SHA256SUMS`, back up both slot-B boot partitions in
fastbootd, and keep a model-correct recovery path before writing `super`.
