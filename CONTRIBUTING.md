# Contributing

Contributions are welcome from OnePlus 7T Pro owners, postmarketOS developers,
Linux maintainers, and people familiar with Qualcomm SM8150. Reports from
regional variants are useful even when no patch is attached.

This is hardware enablement for an unlocked phone. A successful build or probe
is useful evidence, but it is not enough to call a feature working.

## Start here

Before opening an issue or pull request, read:

- [the current support matrix](docs/status.md);
- [device safety and recovery rules](docs/device-safety.md);
- [the build and test workflow](docs/build-and-test.md); and
- [the repository layout and artifact policy](docs/repository-layout.md).

Search existing issues and evidence before starting overlapping work. State
whether your change targets this bring-up repository, postmarketOS pmaports, or
an upstream Linux subsystem.

## Contribution paths

### Hardware reports

A useful report includes:

- exact model number and regional variant;
- kernel repository, branch, commit, and dirty-tree status;
- kernel release plus config, DTB, initramfs, and boot-image SHA-256 hashes;
- boot method, active slot, and locked or unlocked bootloader state;
- the operation performed and its expected result;
- observable display, input, power, network, and USB behavior;
- focused kernel or userspace log excerpts;
- the result of a second clean boot when reproducibility matters; and
- whether recovery was automatic or required physical input.

Use relative timestamps where possible. Redact serial numbers, MAC addresses,
SIM identifiers, credentials, personal photographs, NFC payloads, and other
device-specific or personal data.

### postmarketOS packaging

Keep device packages, firmware packages, kernel packages, and userspace policy
changes reviewable independently. Follow the normal pmaports package shape;
laboratory repacks and files copied into a live root filesystem are validation
tools, not the final package design.

Changes that affect a declared hardware capability need evidence from a clean,
package-shaped image. See the
[pmaports upstreaming plan](docs/pmaports-upstreaming.md) for the current
submission boundary.

### Linux kernel changes

Generic driver, binding, and SoC changes belong upstream whenever possible.
Prepare them against the appropriate maintainer tree, not by extracting a
mixed bring-up diff. Keep board description separate from reusable driver
work, and split unrelated subsystems into separate series.

Linux submissions must follow the kernel DCO and subsystem rules, include a
`Signed-off-by` trailer, pass the relevant `checkpatch.pl`, build, binding, and
schema checks, and document the exact tested tree. Never rewrite a mailed
patch artifact in place; prepare a new version with a changelog and threading.
The current queue and reproduction procedure are in
[Linux upstream submissions](docs/upstream-submissions.md).

### Documentation and tooling

Documentation should describe reproducible public behavior rather than a
private workstation session. Scripts must default to non-destructive behavior,
validate the target identity, bound waits and writes, and leave enough evidence
to understand failures.

Historical D-series, K1, kexec, RGB framebuffer, and downstream 4.14 tooling is
retained for reproduction. Do not make it the default workflow or use it as
evidence for the maintained mainline path.

## Evidence levels

Use precise language in issues, commits, and documentation:

- **Prepared**: source or packaging exists but has not completed its checks.
- **Build-tested**: the relevant build and static checks pass.
- **Boot-tested**: the exact artifact reaches the stated boot checkpoint.
- **Hardware-tested**: the exact artifact exercises the real function through
  a normal Linux interface on the named device variant.
- **Working**: the hardware result is reproducible and its important failure
  paths have been checked.

Do not promote a status because a DT node exists, a driver probes, or a single
command succeeds. Record remaining limitations even when the primary test
passes.

## Device safety

Every hardware-affecting change must identify a known-good recovery image and
the expected recovery path before flashing. Only one process or operator may
control the phone at a time. Stop when the target identity, slot, artifact
hash, power state, or transport differs from the test plan.

Do not repeatedly reset a device in Qualcomm crashdump mode. Do not assume a
host-side USB reset is equivalent to a physical power or VBUS cycle. Partition
writes must follow the allowlist and verification requirements in
[device safety](docs/device-safety.md).

## Repository hygiene

Keep generated and private material out of Git, including:

- boot, rootfs, and partition images;
- proprietary firmware and phone dumps;
- complete runtime logs and RAM dumps;
- credentials and machine-specific configuration; and
- unique device identifiers or personal captures.

Commit source, build recipes, concise redacted evidence, file sizes, and
cryptographic hashes instead. Do not mix cleanup or generated metadata with a
functional change.

## Validation

Run the public-tree validator for every pull request:

```sh
scripts/validate-public-tree.sh
```

It performs the repository's shell, Python, Markdown-link, package-input, and
public-data checks used by GitHub Actions. Also run checks appropriate to the
changed area.

For a changed shell script:

```sh
bash -n scripts/changed-script.sh
shellcheck --severity=warning -- scripts/changed-script.sh
```

For pmaports changes, synchronize into a clean pmaports checkout and run its
normal policy, build, and image checks as described in
[the build workflow](docs/build-and-test.md). For kernel or DT changes, include
the exact `checkpatch.pl`, `W=1` build, `dt_binding_check`, and `dtbs_check`
commands that apply to the patch.

Hardware validation must identify the exact source commit and tree, artifact
hash, boot ID, test duration, result, warnings reviewed, and rollback outcome.
Store durable, sanitized conclusions under `docs/evidence/`.

## Pull requests

Keep each pull request focused and explain:

- the problem and why this layer is the right place to solve it;
- the source and artifact identities;
- offline checks performed;
- hardware checks performed, or an explicit `Not hardware-tested` statement;
- known regressions and remaining gaps; and
- the rescue or rollback path for hardware-affecting changes.

Do not mark a checkbox for a check that was skipped. Reviewers must be able to
distinguish candidate code, compatibility backports, board-only test changes,
and the code intended for upstream submission.

## Complete image releases

A public image release is an atomic boot and rootfs set. Their UUIDs, packaged
kernel, DTB, modules, and firmware must match. Never combine assets from
different releases.

Release candidates require offline integrity checks followed by a full flash
to physical hardware, direct boot, graphical userspace, storage, input, USB or
network recovery access, and a second clean boot. Publish hashes, limitations,
and the matching installation procedure. A boot image tested on an existing
development rootfs is not a complete release.

## Commit messages

Use an imperative subject that names the affected area, for example:

```text
power: document SMB5 hardware validation
scripts: verify boot partition readback
camera: add IMX481 VBLANK coverage
```

Explain why the change is needed and what was actually tested. Avoid claiming
hardware support in the subject when only static or build validation exists.

## Licensing

By contributing, you agree that your original contribution is available under
the repository license. Files derived from other projects must retain their
original license, copyright notices, attribution, and provenance. Do not
commit proprietary files merely because they can be extracted from a device.
