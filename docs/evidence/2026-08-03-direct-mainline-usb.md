# Direct mainline USB gadget bring-up (V34-V41)

Date: 2026-08-03

Device: OnePlus 7T Pro, rear-labelled HD1913 (`hotdog`)

Kernel: ClearStaff-based Linux `6.16.0-sm8150+`

## Result

V41 boots Linux directly from the OnePlus bootloader, mounts the postmarketOS
root filesystem, exposes CDC NCM and ACM, and provides a stable SSH session at
`172.16.42.1`. The host uses `172.16.42.2`. This path does not use the 4.14
bridge kernel or kexec.

The final functional change was to use a translated Apps SMMU domain for DWC3.
V40 attached the controller to stream ID `0x140`, but retained
`iommu.passthrough=1`; its event ring remained unwritten. V41 changed only that
command-line value to `iommu.passthrough=0`. EP0 commands then completed and the
gadget enumerated normally.

Read-only SSH validation reported:

```text
Linux hotdog 6.16.0-sm8150+
/dev/loop1 on /
/dev/loop0 on /boot
usb0: 172.16.42.1/16
```

The USB descriptor identifies a OnePlus 7T Pro running postmarketOS and exposes
four CDC NCM/ACM interfaces. Repeated ping and SSH sessions remained stable.

## Failure boundary

V36 proved that the Qualcomm wrapper, USB2 PHY, DWC3 core, UDC registration,
configfs mount, and NCM configfs construction all completed. V37 localized the
first Qualcomm `900e` transition to DWC3's first soft-connect sequence. V38
skipped the initial `DCTL.CSftRst`, matching the working OnePlus 4.14 startup
order while retaining the upstream reset for later reconnects.

V39 then instrumented the first EP0 command. Crash-memory evidence ended after
the DEPCMD register write and before the first status poll:

```text
HOTDOG_V39_EP_CMD_DEPCMD_WRITE_DONE
```

No corresponding first-poll marker was present. This placed the failure at the
first controller DMA/command transaction rather than in configfs, NCM, ACM, or
userspace.

V40 added the missing DWC3 Apps SMMU attachment:

```dts
&usb_1_dwc3 {
    iommus = <&apps_smmu 0x140 0>;
};
```

That stopped the `900e` transition, but `iommu.passthrough=1` selected an
identity domain. DWC3 reached EP0 setup with a zero event ring and repeatedly
reported unknown endpoint events. V41 selected translated DMA with
`iommu.passthrough=0`. The same first command then returned successfully:

```text
HOTDOG_V39_EP_CMD_FIRST_POLL=6
HOTDOG_V39_EP_CMD_RETURN ret=0 status=0
```

This result demonstrates that merely describing the stream ID is insufficient:
the controller must use the translated domain on this boot path.

## Test progression

| Candidate | Controlled change | Hardware result |
|---|---|---|
| V34 | Enable normal postmarketOS gadget setup on the V33 rootfs path | Entered Qualcomm `900e` during USB setup. |
| V35 | Constrain DWC3 coherent DMA to 32 bits and print allocations | All observed buffers were below 4 GiB; still entered `900e`. |
| V36 | Build NCM configfs state, delay, bind once, and omit ACM | Isolated failure to the first UDC bind. |
| V37 | Trace NCM bind through DWC3 pull-up | Isolated failure to the first soft-connect reset. |
| V38 | Skip `DCTL.CSftRst` only on the first connection | Passed the previous reset boundary; reconnect behavior remains upstream-compatible. |
| V39 | Trace the first EP0 command and IOMMU state | Entered `900e` after DEPCMD write and before its first poll. |
| V40 | Attach DWC3 to Apps SMMU stream `0x140` | Avoided `900e`, but passthrough DMA left the event ring unwritten. |
| V41 | Change only `iommu.passthrough=1` to `0` | NCM, ACM, postmarketOS userspace, ping, and SSH work directly. |

## Hardware inventory

The V41 SSH session was used only for read-only inspection. It confirmed:

- UFS storage and its LUNs, the nested postmarketOS boot and root filesystems,
  and OpenRC userspace are operational.
- DPU/DSI, `card0`, `renderD128`, framebuffer console, panel scanout, and
  backlight control are present.
- DWC3 is in IOMMU group 5 and NCM/ACM enumerate through the translated domain.
- The power key and 27 thermal zones are visible.
- Battery/charging, touch and volume keys, sound, Wi-Fi/Bluetooth, remoteproc,
  cameras, and sensors are not enabled yet.
- `tqftpserv`, `pd-mapper`, and `qbootctl` need follow-up; the normal network,
  SSH, and user-session services start.

The captured logs are intentionally kept outside the public repository under
`logs/mainline-pmos-hardware-2026-08-03-200800`.

## Exact payloads

| Component | SHA256 |
|---|---|
| V34 AVB `boot.img` | `872ac5c363d1e07cfb3a94acc23dba529d8ead3e01b730c5faf9e5770b6e9f19` |
| V35 AVB `boot.img` | `f4e5d957e1293b0cf4a746c0e28bf2228ac515b143c2210fed547fabf5ed6817` |
| V36 initramfs | `fd45c3902bdfec6b122608e77efa00a4894a3b4502218922e593910c36c4d6f0` |
| V36 AVB `boot.img` | `a611368ce382b990868f7789e583eb4ab18309a288411ca8b56ba83f0056a0a3` |
| V37 AVB `boot.img` | `7d24d47d11154d54f27b0e0f7c3e84e6358d939dc8dbb3be41d0d13529939828` |
| V38 AVB `boot.img` | `eeda76d6b98a6eb021260f97360e3a4224ea902390c32faf15583781cd291930` |
| V39 kernel `Image` | `268f2ae209ab11f0840c18c69a8f2a9f11c09108f9b332ebcae599b97466cc5e` |
| V39 AVB `boot.img` | `63512b5bc41aebf3b2252067151da4a343ecd854a4ad299bcdada5bb94cd0ee5` |
| V40 DTB | `cbc56da2741ae9c3b83a04c4111c9bfc31d5ca5985264fbd3434aa0597856d92` |
| V40 AVB `boot.img` | `478aae1ffe9c9159cac767e71813cf3e23085f5d1ef13b56d76d00071b6b1e15` |
| V41 command line | `7c88a4d3054577b7203f827950286c684759b229cce3c174e1d476320cf18f80` |
| V41 AVB `boot.img` | `f7d2f9f51a3c7818df2148c1bf25c72cf7ee1545ac38c9c3847793820bf9b604` |
| V42 kernel `Image` | `264c62696343c93b443e06b4817e35b07b92337298c299703ee24e08ae47e780` |
| V42 command line | `de6f08f3690798e6ec3b20f5ca3b4683fd9efc15dd76ea5c970366afe2aeb4b3` |
| V42 AVB `boot.img` | `baeeeffc6a96f2416038a6468260b609950e63b8bd8b1f4c08d5980d812fe824` |

V42 is a validation candidate, not a new USB fix. It keeps the V41 DTB,
initramfs, translated-IOMMU command line, and direct-entry window, removes the
high-frequency V39 EP0 diagnostics, and selects the built-in Terminus 16x32
console font. It performs no automatic reboot or recovery action.
