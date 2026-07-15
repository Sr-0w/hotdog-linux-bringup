# Mainline bring-up record

This document records the minimum set of changes that produced a real
postmarketOS userspace under Linux 6.17 on the OnePlus 7T Pro HD1913.

The current result is a bring-up checkpoint. Several changes deliberately
bypass broken providers and are not suitable for upstreaming in their present
form.

## Boot result

The validated cycle reaches:

- Linux `6.17.0-sm8150-g379d8fe35c7c-dirty`
- Samsung UFS storage
- the postmarketOS GPT nested in the Android `super` partition
- a read-write ext4 root filesystem
- OpenRC userspace
- USB NCM, USB ACM, and SSH

The complete launcher is `scripts/test-mainline617-pmos-full.sh`. It verifies
the SHA256 of every local boot artifact before executing kexec.

## Verified 2026-07-11 cycle

The public evidence for this cycle is versioned in
[evidence/2026-07-11-mainline-k1.md](evidence/2026-07-11-mainline-k1.md).
It records the K1 payload hashes, kexec/USB/SSH timeline, no-echo ACM capture,
exact `qcom-wdt.ko` module load, reboot behavior, and temporary
`fastboot boot` controls.

This is a historical `CONFIG_QCOM_WDT=m` hardware record. The current r5
package uses `CONFIG_QCOM_WDT=y`, contains no `qcom-wdt.ko` payload member, and
has not been tested on hardware as a complete payload. Revision r4 remains the
latest double-build reproducibility evidence; this does not establish
cross-toolchain reproducibility or hardware behavior.

Summary:

- the exact K1 Linux 6.17 payload reached postmarketOS userspace through the
  downstream kexec bridge
- the ACM capture path was corrected to passive raw/no-echo reading
- the exact K1-compatible Qualcomm watchdog module loaded after userspace and
  registered `watchdog0`
- `RESTART2(bootloader)` from mainline produced a physical reboot back to the
  normal persistent bridge boot, leaving boot-mode mapping unresolved
- the D1 raw direct image returned `OKAY` under temporary `fastboot boot` but
  did not leave the original fastboot USB instance
- bridge raw no-paint, bridge AVB, and Lineage raw controls failed explicitly
  with `Load Error`

Additional run identifiers:
`test-mainline-via-kexec-2026-07-11-163810`,
`pmos-usb-ssh-2026-07-11-164111`,
`mainline617-k1-qcom-wdt-live-2026-07-11-164151`,
`reboot-pmos-bootloader-2026-07-11-164349`,
`pmos-usb-ssh-2026-07-11-164526`,
`direct-d1-acm-2026-07-11-164835`, and
`test-fastboot-boot-image-2026-07-11-164847/165222/165329/165412`.

## 1. Kexec low-bank RAM window

The source-reproduced base hotdog DTB used for the K1 line starts with an
open-ended RAM placeholder:

```dts
memory@80000000 {
    reg = <0x0 0x80000000 0x0 0x0>;
};
```

K1 constrains this to the low-bank window that the downstream kexec bridge can
hand over reliably:

```dts
memory@80000000 {
    reg = <0x0 0x80000000 0x0 0x3bb00000>;
};
```

Builders: `scripts/build-mainline-k1-base-dtb.sh` and
`scripts/build-mainline-kexec-lowbank-dtb.sh`

The complete orchestrator pins the source-built base DTB hash
`44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49` and
reproduces the lowbank DTB hash
`e58d41e039e782f34b5cc1ec6406da833a2e30a54414058cd3e37a60fe10e19d`.
This is a temporary K1/kexec constraint; the direct-boot path still needs the
complete RAM map restored.

## 2. Firmware-owned memory gap

The runtime firmware map reserves `0x86200000-0x8b700000`. The initial
mainline tree left `0x89d00000-0x8b700000` available to Linux, allowing normal
allocations to overlap firmware-owned memory.

The validated DTB adds a `no-map` reservation:

```dts
hotdog-removed-gap@89d00000 {
    reg = <0x0 0x89d00000 0x0 0x01a00000>;
    no-map;
};
```

Builder: `scripts/build-mainline-lowbank-firmware-gap-dtb.sh`

## 3. Apps SMMU failure

The Apps SMMU at `15000000.iommu` fails to register with `-EINVAL`. UFS, QUP,
and DWC3 then remain deferred behind an unavailable IOMMU provider.

For bring-up, `iommus` is removed from:

- UFS at `/soc@0/ufshc@1d84000`
- QUP at `/soc@0/geniqup@ac0000`
- DWC3 at `/soc@0/usb@a6f8800/usb@a600000`

The kernel command line also contains:

```text
iommu.passthrough=1 arm-smmu.disable_bypass=0
```

Builders:

- `scripts/build-mainline-ufs-smmu-bypass-dtb.sh`
- `scripts/build-mainline-pmos-boot-dtb.sh`

This is a temporary bypass. The correct fix is to repair the SMMU description
and client stream IDs.

## 4. UFS ICE dependency

The Qualcomm ICE block fails because `gcc_ufs_phy_ice_core_clk` never reaches
the expected state. The UFS driver can operate without ICE, so the bring-up DTB
removes the UFS `qcom,ice` phandle.

Builder: `scripts/build-mainline-ufs-no-ice-dtb.sh`

The long-term fix must restore the correct clock and ICE integration rather
than permanently dropping inline crypto.

## 5. UFS and nested postmarketOS partitions

Once UFS probes, the Android partition table appears normally. The
postmarketOS disk image is nested inside the `super` partition rather than
being represented by top-level GPT entries.

The initramfs creates loop devices for the nested partitions:

```text
/dev/loop0  pmOS_boot  ext2
/dev/loop1  pmOS_root  ext4
```

The root filesystem then mounts read-write and the normal postmarketOS
`switch_root` path completes.

## 6. Probe ordering and timing

Two timing constraints are currently hardware-validated:

- wait 120 seconds before executing the normal postmarketOS `/init`
- retain the inherited framebuffer probe as a 45-second wait-only poll

A 15-second pre-init delay failed. Removing the framebuffer poll entirely also
caused mainline to reset to the persistent bridge. The earlier RGB test frames
were written by the downstream 4.14 initramfs userspace helper
`/hotdog_fb_test.sh`, not by the Linux 6.17/mainline kernel. The current helper
contains no framebuffer fill code and never emits RGB test frames.
The D1 ramdisk retains the old helper bytes in its first concatenated archive,
but its second archive replaces that path with the wait-only implementation.
The offline validators resolve the final effective member with
`scripts/extract-last-newc-member.py` and reject RGB fill code there.

The stable bridge pointer defaults to the r5 no-paint relay
`2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog`
(`23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50`).
Older dated experiment scripts and images that still hard-code RGB-capable
helpers are historical-only for this path and require the explicit
`HOTDOG_ALLOW_HISTORICAL_RGB=1` opt-in before their wrappers will run.

Builder: `scripts/build-mainline-pmos-wrapper-initramfs.sh`

These waits should eventually be replaced by deterministic device readiness
checks and corrected probe dependencies.

## 7. USB gadget

Removing the DWC3 IOMMU dependency allows the USB controller to probe before
the initramfs performs its one-shot gadget setup. The result exposes:

- USB NCM networking at `172.16.42.1`
- SSH from the postmarketOS rootfs
- USB ACM serial on `ttyGS0`

## Reproduction contract

The current launcher pins:

- the Linux 6.17 Image
- the final hotdog DTB
- the wrapped postmarketOS initramfs
- the downstream no-paint bridge used for recovery

Generated artifacts are intentionally not committed. See
[artifacts.md](artifacts.md) for the expected local layout and verification
rules.

## Remaining technical debt

1. Repair Apps SMMU registration and restore all client IOMMU links.
2. Restore UFS ICE with the correct clock and power dependencies.
3. Replace fixed timing waits with deterministic probe ordering.
4. Describe the full RAM map instead of exposing only the low bank.
5. Bring up display clocks, DSI, panel, and DRM under mainline.
6. Hardware-test the staging PON boot-mode mapping and express the accepted
   result in the maintained kernel source; the observed K1 DTB still lacks it.
7. Validate the exact direct payload from persistent `boot_b`.
8. Validate a package-generated direct image; an offline K1 package build does
   not establish bootloader or hardware equivalence.
