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

Do not assume A/B retry exhaustion will select a successful alternate slot.
On the tested OnePlus bootloader, slot B remained current at retry count zero
and firmware stopped at the red failure screen. An unattended direct-boot test
needs an independently validated reboot-to-fastboot mechanism; the current
experimental path combines a pre-MMU APSS watchdog with PM8150 PON bootloader
mode selection.

### Host-side reset limits

A disconnected USB device cannot receive a USB control request. Disabling its
root-hub port, resetting the xHCI host controller, or cycling VBUS may recover a
host-side link, but none of those operations resets the application processor
of a battery-powered phone. A USB Power Delivery Hard Reset resets the power
contract and PD communications, not the Snapdragon SoC.

Do not depend on host USB power control for unattended direct-boot tests. Many
root hubs do not implement per-port VBUS switching, and Linux cannot report
whether a logically disabled port still supplies VBUS. Every direct candidate
that may stall before USB initialization must therefore arm a hardware reset
path before the first unbounded operation.

On the reference host, the tested HD1913 remained at a fixed boot logo after
all available host-side recovery controls were exercised: logical disable and
reenable of the paired USB2/USB3 ports, an xHCI PCI-function reset, and a full
unbind/rebind of the dedicated xHCI controller. The controller re-enumerated
its other devices, but the phone produced no USB event and its display did not
change. This distinguishes a target-side USB PHY that never initialized from a
stale host-controller association.

For unattended development, add an electrically isolated relay or actuator
that can reproduce the device's verified `Volume Up + Power` hard-reset
combination. Control both button contacts independently and keep the normal
USB data link separate. A remotely switched USB hub or VBUS relay alone is not
a substitute: the handset remains powered by its battery when VBUS disappears.

If the candidate can still reach postmarketOS USB networking, a second watcher
can validate its exact kernel and command line before requesting fastboot:

```bash
scripts/rescue-pmos-to-fastboot-when-visible.sh \
  --expected-kernel-prefix '6.17.0-sm8150' \
  --expected-cmdline-token 'rdinit=/hotdog-mainline-wrapper'
```

This watcher does not flash partitions. Pair it with the prearmed fastboot
restore watcher used by the direct-boot wrappers.

If an experimental watchdog enters Qualcomm Crashdump instead, inspect the
tracked breadcrumb without dumping all RAM:

```bash
scripts/qualcomm-900e-autorescue.sh inspect
```

The same wrapper can issue a protocol-level SoC reset with the `reset` action.
On the tested HD1913 this reset is accepted, but a persistently failing boot
candidate may return to `900e`; it does not alter slots or restore partitions.
Both actions validate the configured serial, acquire the phone-operation lock,
and perform no phone-storage access.

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
