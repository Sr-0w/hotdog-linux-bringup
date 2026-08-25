# OnePlus 7T Pro postmarketOS v0.1.0-alpha.3

`v0.1.0-alpha.3` is the complete-source replacement for Alpha 2. During the
post-publication reproducibility check, three libcamera `r12` patches used by
the clean build were found only in the local pmaports checkout, not in the
Alpha 2 source tag. No private code or binary was involved, but the tag could
not reproduce its own libcamera APK and rootfs.

Alpha 3 uses the same offline-validated payload content as Alpha 2 and changes
only the public versioned filenames, manifest and source tag. The source tag
now contains the complete libcamera `r12` patch series and checksums. Alpha 2
had no downloads when the gap was found and is superseded.

The required atomic set remains:

- the postmarketOS nested-GPT system image;
- the matching 100,663,296-byte AVB boot image; and
- the hardware-validated 25,165,824-byte filtered DTBO image.

Do not mix these files with Alpha 1, Alpha 2 or another build. Verify
`SHA256SUMS`, read the attached `INSTALL.md`, and keep both slot-B backups
before writing anything.

All functional changes and limitations are those documented for
[Alpha 2](release-notes-v0.1.0-alpha.2.md). The exact final image remains
offline-validated and has not yet been booted as a complete set on hardware.
