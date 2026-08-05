# Documentation

The documentation is organized around stable project concepts rather than a
single developer workstation or a live debugging session.

## Start here

- [status.md](status.md): current hardware support matrix and known limitations
- [mainline-bringup.md](mainline-bringup.md): validated mainline fixes and their
  technical rationale
- [direct-boot.md](direct-boot.md): direct bootloader handoff experiments and
  completion criteria
- [boot-flow.md](boot-flow.md): downstream bridge, kexec, initramfs, and rootfs
  architecture
- [host-setup.md](host-setup.md): host requirements and source bootstrap
- [device-safety.md](device-safety.md): required safeguards before hardware tests
- [artifacts.md](artifacts.md): generated artifact contract and hash validation
- [sources.md](sources.md): upstream and reference source trees
- [roadmap.md](roadmap.md): remaining work, ordered by dependency
- [hardware-roadmap.md](hardware-roadmap.md): staged subsystem experiments after
  direct boot is validated
- [pmaports-upstreaming.md](pmaports-upstreaming.md): package architecture,
  validation gates, and submission scope
- [repository-layout.md](repository-layout.md): tracked versus local-only state
- [android-reference.md](android-reference.md): Android-side facts worth capturing

## Research records

Raw experiment records live in the ignored local `reports/` directory. Promote
reusable conclusions into the documents above without publishing device serials,
credentials, proprietary dumps, or workstation-specific paths.

- [evidence/2026-07-30-direct-pid1.md](evidence/2026-07-30-direct-pid1.md):
  direct Linux 6.17 completion through active PID 1 syscalls, the diagnostic
  framebuffer mapping fix, and the observed 511-character ABL command-line
  limit.
- [evidence/2026-08-03-mainline616-pmaports.md](evidence/2026-08-03-mainline616-pmaports.md):
  strict source build and complete current-pmaports image assembly, including
  exact APK, Image, DTB, initramfs, filesystem, deterministic AVB, and
  boot-image hashes.
- [evidence/2026-08-05-mainline616-public-image.md](evidence/2026-08-05-mainline616-public-image.md):
  clean public-package rebuild and a complete Plasma Mobile image, including
  filesystem validation, application inventory, verified `super` staging, and
  remaining first-boot and installation-metadata gates.
- [evidence/2026-08-04-mainline616-touchscreen.md](evidence/2026-08-04-mainline616-touchscreen.md):
  exact `r4` APK kernel/DTB direct boot and hardware validation of the Samsung
  S6SY761 controller, IRQ, coordinates, pressure, and multitouch slots.
- [evidence/2026-08-04-mainline616-gpu.md](evidence/2026-08-04-mainline616-gpu.md):
  reproducible `r5` package, exact direct-boot attestation, Adreno 640/GMU
  firmware and render-node validation, and real Turnip Vulkan submissions.
- [evidence/2026-08-04-mainline616-volume-keys.md](evidence/2026-08-04-mainline616-volume-keys.md):
  reproducible `r6` package, exact direct-boot attestation, and registration of
  the Power, Volume Down, Volume Up, and touchscreen input devices.
- [evidence/2026-08-04-mainline616-battery-charger.md](evidence/2026-08-04-mainline616-battery-charger.md):
  clean R6-derived discovery build, direct PM8150B registration, and the
  superseded SMB2-conversion safety finding.
- [evidence/2026-08-04-mainline616-smb5-parameters.md](evidence/2026-08-04-mainline616-smb5-parameters.md):
  reproducible `r8` package, corrected generation-specific charger limits,
  direct PMIC register verification, and the guarded 61-sample hardware trace.
- [evidence/2026-08-04-mainline616-graphical-userspace.md](evidence/2026-08-04-mainline616-graphical-userspace.md):
  physical KMS acceleration, correct 1440x3120 Weston scanout, graphical touch
  validation, and a usable Plasma Mobile session on direct-mainline `r8`.
- [evidence/2026-08-04-mainline616-display-90hz.md](evidence/2026-08-04-mainline616-display-90hz.md):
  stock-DTBO timing derivation, reproducible `r16` package and boot image, and
  direct hardware proof of an active 1440x3120 90 Hz DRM mode.
- [evidence/2026-07-12-packaging.md](evidence/2026-07-12-packaging.md): public
  evidence for the device kernel split, initramfs cleanup, firmware usrmerge,
  and the validated `20241212-r0` APK set.
- [evidence/2026-07-12-direct-boot.md](evidence/2026-07-12-direct-boot.md):
  persistent D1 and D1-pack results, verified R5 rollback, and the exact
  D2 and D3 results, verified rollback, and the prepared D3-wdt control.
- [evidence/2026-07-11-mainline-k1.md](evidence/2026-07-11-mainline-k1.md):
  primary public evidence for the hardware-observed K1 kexec cycle,
  including payload hashes, the kexec timeline, and direct-boot controls.
- [evidence/k1-kernel-package.md](evidence/k1-kernel-package.md): historical r0
  hashes, the intermediate r3 reproducibility diagnosis, and exact r4
  double-build evidence from the tested pmbootstrap environment.
- [evidence/k1-dtb-source.md](evidence/k1-dtb-source.md): buildable K1 hotdog
  DTB source baseline and exact source-to-observed-final-DTB transform chain.
