# Artifact retention

The bring-up workspace retains artifacts that are required to reproduce the
current port, diagnose unresolved hardware issues, or recover the test device.

## Retained

- The public pmaports packages, helper scripts, documentation, and source
  checkouts under this repository.
- Mainline boot images for the known-good IMX586 baseline (`r100`) and the
  latest autofocus experiments (`r105` through `r107`).
- A compact copy of the downstream 4.14 R6 rescue boot image and its manifest.
- The OxygenOS 10.0.13 vendor extraction used to identify firmware, camera
  modules, calibration data, and hardware topology.
- The complete R107 RAM dump captured after a software reboot entered Qualcomm
  Sahara crashdump mode on 2026-08-10. It is kept locally because it contains
  device memory and is not suitable for publication.
- Kernel symbols that correspond exactly to retained crash dumps.

## Regenerable artifacts

The following are intentionally not retained indefinitely:

- pmbootstrap chroots and package caches;
- unpacked boot-image components when the original boot image is retained;
- duplicate kernel source worktrees used for one-off bisection steps;
- webcam recordings and repeated full-RAM captures whose findings are already
  represented by a retained capture and public evidence document;
- historical build directories that can be reproduced from the committed patch
  series.

Large local diagnostic artifacts should be summarized in `docs/evidence/`
before removal. Public documentation must contain the relevant hashes,
commands, observations, and conclusions without publishing private RAM data.

## 2026-08-10 cleanup

The legacy bring-up tree was reduced from approximately 768 GiB to 84 GiB and
the active repository from approximately 79 GiB to 22 GiB, leaving
approximately 750 GiB free on the host filesystem. Removed data
included old pmbootstrap chroots, package caches, historical image sets,
duplicate RAM captures, disposable build worktrees and webcam recordings.
Stale chroot bind mounts were unmounted before their directories were removed.

The cleanup retained the OxygenOS hardware reference, source checkouts, public
repository, R6 rescue image, current `r105` through `r108` development line,
the exact R107 symbols and its single complete RAM capture. This is the model
for later cleanups: retain reproducible source plus a small rolling build
window, one known-good rescue artifact and unique diagnostic evidence.
