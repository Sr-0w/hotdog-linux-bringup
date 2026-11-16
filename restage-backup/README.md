# Pre-restage source checkpoint — 2026-11-16

This branch preserves the local clean-baseline working tree, including the
uncommitted DisplayPort-presence and ramoops patches and watchdog settings.
It is an experimental checkpoint, not a newly validated release.

## Recover on a new workstation

```sh
git clone --branch backup/pre-restage-2026-11-16 https://github.com/Sr-0w/hotdog-linux-bringup.git
cd hotdog-linux-bringup
```

Follow `docs/build-and-test.md` to install host dependencies and obtain source
repositories. Recreate `hotdog.env` and `pmbootstrap_v3.cfg` from their examples
and adjust paths for the new workstation. The kernel/package build and phone
hardware have NOT been tested for this checkpoint.

Local bringup branch tips are preserved remotely under
`backup/restage-2026-11-16/<original-branch>`.
`bringup-branches.txt` records their original commit IDs.

## Additional source snapshots

`manifest.json` records the exact base and head commits for external trees.
For each kernel branch, check out its base commit in the corresponding kernel
repository and apply the listed patch with `git apply`. These are cumulative
source diffs, not complete kernel repositories or independent patch series.
The SM8150 base is from the postmarketOS Qualcomm SM8150 Linux repository;
the older Hotdog base is the clearstaff 6.16 tree referenced by the project.

For pmaports, check out the recorded base commit in
https://github.com/sm8150-linux-mainline/pmaports.git, apply `working-tree.patch`,
and copy the contents of `untracked/` into that checkout preserving paths.
For the dirty q6afe tree, first restore its matching kernel branch snapshot,
then apply its `working-tree.patch`. Do not apply every snapshot to one tree;
they represent separate experiments.

## Files that still require a separate backup

This is a source checkpoint, not a disk backup. Generated boot/rootfs images,
phone dumps, full logs, credentials, machine configuration, proprietary modem
and SLPI firmware are excluded. `manifest.json` lists five binary inputs
omitted from the pmaports snapshot; preserve those privately if needed.
Some may also be recoverable from existing tracked packages or stock firmware,
but this checkpoint does not guarantee their recovery. Keep the existing
Projects directory backup for research notes and stock/recovery inputs.

The snapshot covers the top-level Hotdog bringup worktrees and source changes
identified in the pmaports and kernel worktrees. Ignored build/cache trees,
nested historical checkouts and outgoing upstream work are not a complete
part of this archive. Rebuilding requires external downloads and the relevant
firmware inputs, not only this clone.

Two stale APKBUILD SHA-512 entries (kernel command line and clean-kernel
validator) were corrected to match the saved files during archival.

## Validation record

Shell syntax, ShellCheck and Python syntax passed. The full public-tree
validator stops at two relative documentation links in the copied historical
pmaports README, whose original surrounding documentation is not copied.
Archived patch whitespace is preserved verbatim. SHA-512 entries for existing
local inputs of the two modified active packages were checked and corrected.
No complete package/kernel rebuild or hardware validation was performed.
