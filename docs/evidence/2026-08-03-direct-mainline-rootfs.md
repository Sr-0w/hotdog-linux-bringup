# Direct mainline UFS and rootfs boot (V33)

Date: 2026-08-03  
Device: OnePlus 7T Pro, rear-labelled HD1913 (`hotdog`)  
Kernel: ClearStaff-based Linux `6.16.0-sm8150`

## Result

V33 booted directly from the OnePlus bootloader, initialized the native panel,
enumerated UFS, mounted the nested postmarketOS root filesystem read-write, and
completed `switch_root`. This path does not execute the downstream 4.14 kernel
and does not use kexec.

The visible rootfs status confirmed:

```text
[hotdog-super-loop] resizing nested pmos_root partition to fill /dev/sda15
loop0: detected capacity change from 0 to 983040
loop1: detected capacity change from 0 to 28360664
[pmOS-rd]: Auto-repair and check 'ext' filesystem (/dev/loop1)
[pmOS-rd]: Mount root partition (/dev/loop1) to /sysroot (read-write)
[hotdog-watchdog] marker: root-mounted
[pmOS-rd]: Switching root
udevd[1835]: starting version 3.2.14
[hotdog-visible-tty-shell] starting /usr/local/bin/hotdog-visible-tty-shell on tty1
```

The rootfs USB hook also ran, but no inherited gadget existed:

```text
[hotdog-rootfs-usb-acm] arming rootfs USB ACM getty
[hotdog-rootfs-usb-acm] could not update configfs: waiting for inherited ttyGS0
```

Direct USB networking, ACM, and SSH are therefore not part of this result.

## Exact payload

| Component | SHA256 |
|---|---|
| V33 kernel `Image` | `728a53058a94f21c85e9a4a053d4bc87b91340a78f1635315912077cd706b47f` |
| Effective native-panel DTB | `1d41e88dbcbfee960eebaf9e2c306b22e43ab05c09eee2f3e5f28106b326bbd4` |
| Diagnostic postmarketOS initramfs | `e4c563fcfc6f2a3533fd16539dd22a3fc578bf858e450a9ae7f66d212ae49ec3` |
| Kernel command line | `902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6` |
| D7 filtered `dtbo_b` | `d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd` |
| Partition-sized AVB `boot.img` | `9f0abd8eb79f8b1f694a822bb537401958b879f5dec59339f6164751279c3adb` |

Artifact directory (generated locally, not committed):

```text
images/pmos-experiments/2026-08-03-200000-clearstaff616-direct-entry-v33-ufs-dma32
```

Hardware run record:

```text
logs/clearstaff616-direct-direct-entry-v33-ufs-dma32-2026-08-03-180836
```

The launcher wrote only `dtbo_b` and `boot_b`, selected slot B, and issued one
reboot. It performed no timeout reset, recovery action, or automatic restore.

## Failure isolation

V32 kept the same DTB, initramfs, command line, panel path, and UFS link setup.
Its one-shot pre-clear dump captured the first timed-out NOP OUT:

```text
HCS=0000000f HCE=00000001
UTRL BA=00000001:02771000 DB=00000000 RS=00000001
outstanding=80000000
UIC errors: all zero
TRD OCS=0xf
response UPIU: all zero
```

The controller was operational and removed the doorbell, but never completed
the descriptor. The coherent transfer-request list lived above 4 GiB while the
temporary bring-up DT had removed the UFS `iommus` property to bypass the
non-registering Apps SMMU.

V33 added a Qualcomm UFS `set_dma_mask` callback. It selects a 32-bit coherent
DMA mask only when both conditions are true:

1. the host is compatible with `qcom,sm8150-ufshc`; and
2. its DT node has no `iommus` property.

No DT, PHY, reset, gear, timing, initramfs, or command-line change accompanied
this test. UFS enumeration and rootfs handoff on V33 therefore validate the DMA
addressability hypothesis for this bypass configuration.

## Scope of the workaround

The DMA constraint is intentionally conditional and temporary. The publication
target remains a correct Apps SMMU description with the UFS IOMMU link restored.
The V33 diagnostic ordering and timeout dump are also bring-up instrumentation,
not proposed upstream interfaces.

Next boundaries:

1. register a DWC3 UDC and restore postmarketOS NCM/ACM/SSH;
2. correct the repeated native DSI scanout geometry;
3. repair Apps SMMU and UFS ICE rather than retaining bypasses;
4. validate touch, Wi-Fi, Bluetooth, audio, modem, charging, and cameras;
5. carry the validated fixes into the pmaports kernel/device packages.
