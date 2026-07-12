# Device safety

This project performs low-level boot experiments. Read this document before
running any script that uses ADB, fastboot, EDL, or raw block devices.

## Assumptions

- The bootloader is already unlocked.
- The device is dedicated to development.
- All valuable user data has been removed.
- Stock partition backups exist outside the phone.
- The operator can physically reach the device if every remote channel fails.

Unlocking a bootloader normally erases user data. This repository does not
automate bootloader unlocking.

## Back up first

Capture and verify the partitions required to recover the active boot stack,
including both A/B copies where applicable:

- `boot_a` and `boot_b`
- `dtbo_a` and `dtbo_b`
- `vbmeta_a` and `vbmeta_b`
- recovery or vendor boot partitions used by the installed Android build
- partition-table metadata and any device-specific calibration data available
  through the chosen recovery path

Do not treat an unverified file copy as a backup. Record its size and SHA256,
and test that the corresponding unpacking tool recognizes it.

## Configure device-specific values

Public scripts do not assume a personal USB serial or password. Export local
values before use, or store the same values in an ignored `hotdog.env` file:

```bash
export ANDROID_SERIAL='<fastboot-or-adb-serial>'
export PMOS_HOST='172.16.42.1'
export PMOS_USER='user'
export PMOS_PASSWORD='<postmarketOS-password>'
```

## Partition-write policy

The mainline kexec launcher does not write a mainline image to a partition.
Bridge testing may update `boot_b`, and the relevant wrappers explicitly refuse
to target another partition.

Never modify `super`, `vbmeta`, `dtbo`, or both boot slots merely to reproduce a
mainline experiment. An explicit DTBO experiment must pin both candidate and
original hashes, restore original `dtbo_b` before the known-good `boot_b`, and
use the versioned dual-partition rescue contract. Understand the exact script
and artifact first.

## Rescue paths

Before a risky boot:

1. verify the known-good restore image and its hash
2. confirm that fastboot or recovery ADB can see the device
3. start a rescue watcher
4. confirm that only one phone-operation lock is active
5. keep the USB cable and power source stable

The main wrappers use `logs/phone-operation.lock` to serialize device writes.
Do not delete a live lock to force concurrent flashing operations.

## Reporting a failed test

Include:

- exact phone model and bootloader state
- active slot before the test
- kernel commit and SHA256
- DTB SHA256
- initramfs SHA256
- boot method: direct boot, flashed slot, or kexec
- USB IDs and descriptor version observed by the host
- whether fastboot, recovery, NCM, ACM, or SSH returned

Do not publish unique device identifiers, credentials, private partition dumps,
or proprietary firmware blobs in an issue.
