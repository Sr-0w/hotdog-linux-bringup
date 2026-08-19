# Boot images on this handset are AVB-signed, and a bare image bricks the slot

Date: 2026-08-19

## What happened

A one-property device-tree change was tested by repacking the running boot
image and writing it to the inactive slot with `dd`, then switching slots. The
phone did not come back. It reached fastboot, then, after the retry budget was
spent, the OnePlus corrupt-image screen.

The change was not at fault. The repack was verified byte-identical to the
image already on the device when built with the original DTB, so the only
difference was the device tree. But the write was still wrong.

## The partition is larger than the image

`boot_b` is 100,663,296 bytes and the Android image inside it ends at
42,323,968. What follows is not padding:

| offset | content |
| ---: | --- |
| 42,323,968 | `AVB0`, the vbmeta block for this image |
| 100,663,232 | `AVBf`, the AVB footer, at partition end minus 64 |

Writing only the 42 MB image leaves the previous slot's `AVB0` and `AVBf` in
place, describing a payload that is no longer there. Verification then fails.
That is what took the slot down, not the device tree.

The project's own `scripts/build-mainline-direct-bootimg.sh` already does this
correctly, with `avbtool add_hash_footer --partition_name boot`, and its help
text says so plainly. It was not used here.

## `fastboot boot` is not available on this device

Worth recording because it invalidates a plan that looks obviously safe.
Loading an image into RAM without touching any partition is refused:

```
Booting   FAILED (remote: 'Failed to load/authenticate boot image: Load Error')
```

That was with an image **byte-identical to the one the phone boots from**, so
it is not about the image. The bootloader will not RAM-boot anything it cannot
authenticate. Any boot experiment on this handset therefore has to go through a
slot, signed.

## Fastboot is reachable after all, by failing a slot

[2026-08-19-pd-hard-reset-charge-gap.md](2026-08-19-pd-hard-reset-charge-gap.md)
and the SLPI notes both record that there is no software path into fastboot:
the `misc` BCB `bootone-bootloader` command is ignored by ABL and mainline
declares no `reboot-mode`. That remains true for *deliberately* entering
fastboot from a working system.

It is not true that fastboot is unreachable. A slot that fails authentication
drops straight into it, with USB enumerating as `18d1:d00d`, and from there
`fastboot set_active` and `fastboot flash` both work. Recovery from this
incident was entirely in software.

## What made recovery possible

The whole 96 MiB partition had been dumped before writing, not just the image:

```
dd if=/dev/disk/by-partlabel/boot_b bs=1M count=96
```

That dump carries the `AVB0` block and the `AVBf` footer, so flashing it back
restores the slot exactly. It is kept at
`images/rescue/boot_b-original-avb.img`, sha256
`e9c3a5ad507c8198104a87ec7ec13b12b15bf3dd7eade155921717f480b92774`.

**Always dump the full partition before writing a boot slot, and always sign.**

## The device-tree change is still untested

`qcom,nsessions = <4>` on the SLPI's `compute-cb@3` has not been evaluated. The
boot failure says nothing about it. Retesting means building the image through
the signing path, not around it.
