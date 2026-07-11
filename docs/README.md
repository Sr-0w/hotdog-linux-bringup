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
- [repository-layout.md](repository-layout.md): tracked versus local-only state
- [android-reference.md](android-reference.md): Android-side facts worth capturing

## Research records

Raw experiment records live in the ignored local `reports/` directory. Promote
reusable conclusions into the documents above without publishing device serials,
credentials, proprietary dumps, or workstation-specific paths.

- [evidence/2026-07-11-mainline-k1.md](evidence/2026-07-11-mainline-k1.md):
  primary public evidence for the hardware-validated K1 Linux 6.17 cycle,
  including payload hashes, the kexec timeline, and direct-boot controls.
- [evidence/k1-kernel-package.md](evidence/k1-kernel-package.md): successful K1
  `pmbootstrap` APK build evidence and pinned payload hashes.
- [evidence/k1-dtb-source.md](evidence/k1-dtb-source.md): buildable K1 hotdog
  DTB source baseline and exact source-to-tested-DTB reproduction chain.
