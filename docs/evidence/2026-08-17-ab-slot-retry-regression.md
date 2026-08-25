# A/B retry marking regressed out of the complete images

> Superseded for the current package line: automatic success marking and
> repeated reboot now work. Retry exhaustion is still not a rescue mechanism;
> see [current status](../status.md).

Date: 2026-08-17

## Status

Resolved. The automatic boot-success marking described in
[2026-08-10-ab-slot-success.md](2026-08-10-ab-slot-success.md) was packaged and
committed but never reached the device. Every complete image since 10 August
shipped a rootfs predating the fix, so no boot ever marked its slot successful
and the bootloader eventually declared slot B unbootable. `qbootctl` is now
installed and enabled on the running rootfs and the slot is marked successful.

## Failure as observed

On 16 August a boot candidate was flashed to `boot_b` and the phone never came
back: no USB gadget, no SSH, no fastboot and no Qualcomm `900e`. The session
that flashed it read those three absences as a failed kernel and stopped.

That reading was wrong. The bootloader state on 17 August was:

```text
current-slot: b
slot-successful:b: no
slot-unbootable:b: yes
```

This is retry exhaustion, the exact failure mode already recorded on
10 August, where the bootloader falls back to the invalid slot-A image and
shows the OnePlus "current image ... destroyed" screen. That screen presents no
USB device of any kind, which is why the three negative probes looked like a
dead kernel.

`fastboot set_active b` restored seven attempts and the previously flashed
image booted normally in 11 seconds, proving the image had never been at fault.

## Why the fix never shipped

`device-oneplus-hotdog` gained the `soc-qcom-qbootctl` dependency in `pkgrel=18`
(commit `9c16c8e`). The rootfs running on the phone was built once, and its
`/lib/apk/db/installed` is frozen at 2026-08-10 01:57 with
`device-oneplus-hotdog-3-r16` installed.

Every "complete image" produced afterwards rebuilt only the kernel, the modules
and the boot image, reusing that same validated rootfs. The device package on
the phone therefore stayed at r16 for a week while the repository advanced to
r25, and `qbootctl` was never installed:

```text
qbootctl binary            : absent
/etc/init.d/qbootctl       : absent
runlevel default           : no qbootctl service
apk info | grep qbootctl   : no match
```

The measurement that confirms the consequence: immediately after
`fastboot set_active b` the counter reads 7, and after a single normal boot it
reads 6. Nothing on the device ever put it back.

## Fix applied

`qbootctl` 0.2.2-r1 and `qbootctl-openrc` 0.2.2-r1 were installed from the
local copies in `tools/apks/qbootctl/`, the slot was marked, and the service was
added to the default runlevel:

```text
SLOT _b: Marked boot successful
 * service qbootctl added to runlevel default

Current slot: _b
SLOT _a:  Active 0  Successful 0  Bootable 1
SLOT _b:  Active 1  Successful 1  Bootable 1
```

## Remaining gap

The running rootfs is patched in place; the image pipeline is not. Any future
complete image built from the same frozen rootfs will reintroduce the same
trap. Closing this properly requires either rebuilding the rootfs from current
aports so it picks up `device-oneplus-hotdog-3-r25`, or adding an explicit
`qbootctl` install step to the image build.

Until then, the operational rule is that a flash cycle passes through fastboot
and `fastboot set_active b` rearms the counter for free, so only long sequences
of reboots *without* a flash can exhaust it. That is exactly what happened on
16 August, where module swaps and boot tests produced more than seven reboots
between two flashes.
