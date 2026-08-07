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
  filesystem validation, application inventory, automatic deterministic AVB
  generation, verified `super`/`boot_b` staging, direct hardware boot, and
  smooth 0 A.D. gameplay on the clean image.
- [evidence/2026-08-05-mainline616-adsp.md](evidence/2026-08-05-mainline616-adsp.md):
  strict `r23` package and AVB hashes, complete `boot_b` readback, and direct
  hardware validation of the ADSP firmware, remoteproc state, and APR audio
  services before codec or sound-card enablement.
- [evidence/2026-08-05-mainline616-wcd9340.md](evidence/2026-08-05-mainline616-wcd9340.md):
  strict `r24` package and AVB hashes, complete `boot_b` readback, and direct
  hardware validation of SLIMbus enumeration plus WCD9340 codec, GPIO, and
  SoundWire binding before machine-card enablement.
- [evidence/2026-08-05-mainline616-audio-card.md](evidence/2026-08-05-mainline616-audio-card.md):
  strict `r25` package and AVB hashes, complete `boot_b` readback, and direct
  hardware validation of the SM8150 ALSA card plus `MultiMedia1` playback and
  capture PCM devices before physical audio routing.
- [evidence/2026-08-05-mainline616-headphone-backend.md](evidence/2026-08-05-mainline616-headphone-backend.md):
  strict `r26` package and AVB hashes, complete `boot_b` readback, and direct
  hardware validation of silent 48 kHz stereo playback through the Hotdog
  `SLIMBUS_6_RX` to WCD9340 `AIF4_PB` digital headphone backend.
- [evidence/2026-08-05-oxygenos-hardware-reference.md](evidence/2026-08-05-oxygenos-hardware-reference.md):
  hash-only OxygenOS hardware inventory policy, stock firmware/module map, and
  reproducible DTB/DTBO reconstruction plus the recovered two-amplifier
  TFA9874/ADSP contract.
- [evidence/2026-08-05-mainline616-tfa9874-probe.md](evidence/2026-08-05-mainline616-tfa9874-probe.md):
  strict `r28` package and AVB hashes, complete `boot_b` readback, and direct
  hardware validation of both TFA9874 revisions with a read-only driver that
  leaves reset lines, routes, protection, and output stages untouched.
- [evidence/2026-08-07-mainline616-usb-role.md](evidence/2026-08-07-mainline616-usb-role.md):
  Type-C port management and dual-role capability. Records the device-tree
  gap that made host mode unreachable, and what is still unvalidated.
- [evidence/2026-08-07-mainline616-suspend.md](evidence/2026-08-07-mainline616-suspend.md):
  incomplete suspend bring-up. Records the staged `pm_test` instrumentation,
  the touchscreen resume failure, and the shared regulator rail behind it.
- [evidence/2026-08-07-mainline616-microphone.md](evidence/2026-08-07-mainline616-microphone.md):
  working handset microphone on AMIC4. Records the three separate defects behind
  it, the stock-overlay bias wiring, the pad sweep that separates live inputs
  from front-end noise, and two measurements that looked like proof but were
  not.
- [evidence/2026-08-05-mainline616-internal-speakers.md](evidence/2026-08-05-mainline616-internal-speakers.md):
  stock-derived S24_LE and TDM-slot contract, bounded amplifier sequencing,
  independent webcam-microphone validation of both internal speakers on the
  direct-booted `r32` kernel, and packaged Plasma/PulseAudio UCM integration.
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
- [evidence/2026-08-04-mainline616-battery-charger-preflight.md](evidence/2026-08-04-mainline616-battery-charger-preflight.md):
  `r10` build-reproducibility record for the conservative PM8150B limits, with
  its hardware safety gate left uncompleted. Superseded by the accepted
  battery/charger and SMB5 results above.
- [evidence/2026-08-04-mainline616-mpss-rmtfs-preflight.md](evidence/2026-08-04-mainline616-mpss-rmtfs-preflight.md):
  `r11` build-reproducibility record for staging MPSS and read-only RMTFS
  independently from WCN3990. Superseded by the accepted Wi-Fi/MPSS result.
- [evidence/2026-08-04-mainline616-adsp-preflight.md](evidence/2026-08-04-mainline616-adsp-preflight.md):
  `r12` build-reproducibility record for the ADSP PAS remote processor with
  every sound-card path left disabled. Superseded by the accepted ADSP result.
- [evidence/2026-08-04-mainline616-wcd9340-preflight.md](evidence/2026-08-04-mainline616-wcd9340-preflight.md):
  `r13` build-reproducibility record for the SLIMbus transport and WCD9340
  codec description, never flashed. Superseded by the accepted WCD9340 result.
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
