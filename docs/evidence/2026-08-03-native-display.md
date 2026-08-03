# Direct-boot native display bring-up

Date: 2026-08-03

This note records the first readable native DRM console produced by a kernel
launched directly by the OnePlus bootloader. It is separate from the retained
firmware framebuffer and from the downstream 4.14 kexec bridge.

## Reproducible V30 contract

V30 combines the direct-entry arm64 Image contract proven by V13 with the
native SM8150 display graph and the OnePlus Samsung DSC panel sequence. The D7
filtered vendor overlay is replayed against the packaged DTB before the image
is accepted, so its bootloader-time effects are checked offline.

| Component | SHA256 |
|---|---|
| V30 AVB boot image | `eb3934f588e77baba78fa524ec370f53d4308d18097009d07571609af56e97a2` |
| Kernel Image | `895432d812868fb1eed238cb0a2af4570c7953e1503f38db9b9d7b9bc493bf0d` |
| Embedded DTB | `1d41e88dbcbfee960eebaf9e2c306b22e43ab05c09eee2f3e5f28106b326bbd4` |
| postmarketOS initramfs | `e4c563fcfc6f2a3533fd16539dd22a3fc578bf858e450a9ae7f66d212ae49ec3` |
| Kernel command line | `902b55b27a157cc6ff14ce5acd155e4b118b1754a9ba8a0707117593071df8f6` |
| D7 filtered DTBO | `d23564d42c989c2b86f760937cb6ea8d570074b20b74bd8c0bc0b94d2ba0d8cd` |

The command-mode panel uses two 720-pixel DSC slices for each 1440-pixel line.
V29 added the missing slices-per-packet field to DRM DSC state and corrected
the MSM DSI transport to send 1440 payload bytes in one packet per line with a
word count of 1441. V30 then packs the calculated DSC state into the standard
128-byte PPS and sends it after the vendor panel-on sequence. This matches the
ordering of the downstream `DSI_CMD_SET_PPS` path.

The kernel source and binary contract can be reproduced with:

```bash
./scripts/prepare-clearstaff616-source.sh
./scripts/build-clearstaff616-v30-kernel.sh
```

The preparation script pins ClearStaff commit
`403b56c33e2ccdda25d90378970a5e5b928dee19`, applies the public patch series,
and verifies a selected-source manifest. The build script uses the exact V30
configuration and historical build identity, then rejects any arm64 `Image`
whose hash differs from the hardware-tested value above.

A clean rebuild from a freshly prepared source tree reproduced the tested
`Image` byte for byte (`895432d812868fb1eed238cb0a2af4570c7953e1503f38db9b9d7b9bc493bf0d`).
It also reproduced the kernel, arm64 vDSO, and compat vDSO Build IDs
`2cfecdea6c10d0a3724fa4eeb831ea9150eb5f55`,
`8ee32136b7fe2e5baa330cb2b41bc760fc9ef854`, and
`22f05e7e0908fbb895c66458fa25ea1883689b11`, respectively.

## Hardware result

The guarded transaction started from manually exposed Fastboot at 16:48:11,
flashed only the pinned D7 `dtbo_b` and V30 `boot_b`, selected slot B, and sent
the single reboot needed to enter the candidate. Observation was passive; no
watchdog, failure panic, Sahara reset, rollback, or other recovery action was
armed.

The physical display showed readable kernel output including these milestones:

```text
msm_dpu ae01000.display-controller: bound ...
[drm] Initialized msm 1.12.0 for ae01000.display-controller on minor 0
fb0: msm ... frame buffer device
Console: switching to colour frame buffer device 180x195
```

PID 1 then entered the postmarketOS initramfs and printed its stage-one output.
The same screen also retained the direct-storage failure:

```text
ufshcd_verify_dev_init: NOP OUT failed -11
Initialization failed with error -11
```

V30 therefore proves native DPU, DSI, DSC, panel, DRM framebuffer, fbcon, EL0,
and postmarketOS initramfs execution in one direct boot. It does not prove UFS,
rootfs mounting, direct USB, or a graphical session.

## Remaining display ambiguity

The dense console image appears repeated vertically. The output is readable,
which rules out the earlier random-color DSC failure, but a scrolling console
cannot distinguish incorrect scanout geometry from fbcon copy/scroll damage.
Changing DSC parameters again would mix those two hypotheses.

V31 is therefore an initramfs-only diagnostic. Its kernel, DTB, command line,
and D7 overlay are byte-identical to V30. PID 1 saves `dmesg` in RAM, suppresses
new console printk, clears `tty0`, and draws five large static color bands at
unique rows before leaving an interactive BusyBox `ash` shell on `tty0`.
It never reboots. The V31 AVB image SHA256 is:

`cacc4751e1b2f3ed8085c0db0d1ff443d75ecfb57b7c6295d8187f4048b70834`

If each V31 band appears once and in order, the native scanout geometry is
usable and the next display fix belongs in fbcon or console handling. If bands
are duplicated or displaced, the correction belongs in the DPU/DSI/DSC mode
programming while V30 remains the known-good execution baseline.
