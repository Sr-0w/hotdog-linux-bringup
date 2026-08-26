# Bluetooth: two driver bugs behind one dead controller

Date: 2026-08-26

The README lists the controller lifecycle as Broken: `hci0` stays `DOWN` with a
locally administered address, `qca_suspend()` aborts every system suspend, and
`rmmod hci_uart` panics. The phone was unavailable, so this is source and
firmware analysis against the traces already recorded in
[suspend/resume defects](2026-08-17-suspend-resume-defects.md). Nothing here is
hardware-validated.

## The firmware is a red herring, but the provenance is worth recording

The OnePlus firmware packages hold a FAT16 `bluetooth.img` with fifteen files.
Comparing the two the device tree actually selects against what we ship:

| file | packaged | OxygenOS 11.0.9.1 |
| --- | ---: | ---: |
| `crbtfw21.tlv` | 229812 | 224892 |
| `crnv21.bin` | 4710 | 4692 |
| `crbtfw11.tlv`, `crbtfw20.tlv`, `crnv11.bin`, `crnv20.bin` | identical | identical |

Only revision 21 differs, and only revision 21 is used. The builds are
`BTFM.CHE.2.1.5-00254-QCACHROMZ-1` for ours against `-00167-QCACHROMZ-1` for
OxygenOS: same branch, ours newer, and ours comes from the community
`sm8150-linux-mainline/firmware-oneplus-hotdog` repository rather than from the
phone.

This is not the cause. The recorded failure is `no firmware was ever
downloaded`, which happens before any file is read, and the same packaged
firmware was hardware-validated on `r15` — scan plus a sustained HID
connection. Recorded because a firmware whose provenance is a third-party
repository is worth knowing about, not because it explains anything.

The board-ID NVM variants in the same image (`crnv21.b44` through `.b71`) are
also a dead end: `btqca` only derives `crnv%02x.bin` for WCN3990, and the
board-ID forms belong to WCN6855, WCN7850 and QCA2066.

## Bug 1: shutting down through a port that was never opened

`qca_power_shutdown()` sets the baud rate and sends a power pulse. Both need an
open serdev port:

```c
	case QCA_WCN3998:
		host_set_baudrate(hu, 2400);
		qca_send_power_pulse(hu, false);
```

`host_set_baudrate()` checks `hu->serdev`, which exists from probe onward. It
does not check that the port is *open*, and only `hci_uart_open()` opens it —
setting `HCI_UART_PROTO_READY`. `ttyport_set_baudrate()` then does:

```c
	struct tty_struct *tty = serport->tty;
	struct ktermios ktermios = tty->termios;
```

with no NULL check, and `serport->tty` is only set between open and close.

So a controller that never comes up leaves `hci0` down, the port closed, and
`serport->tty` NULL. `qca_serdev_remove()` calls `qca_power_shutdown()` *before*
`hci_uart_unregister_device()`, which is how `rmmod` reaches a NULL tty and
oopses in `tty_set_termios()` — exactly the recorded trace.

The fix guards the two operations that need the port and keeps the regulator
teardown, which has to happen regardless.

## Bug 2: a dead controller fails suspend for the whole machine

`qca_suspend()` waits for `QCA_IBS_DISABLED` to clear. That flag is set while a
firmware download is in flight and cleared when one completes, so a setup that
never completes leaves it set forever:

```c
		wait_on_bit_timeout(&qca->flags, QCA_IBS_DISABLED,
			    TASK_UNINTERRUPTIBLE, msecs_to_jiffies(wait_timeout));
		if (test_bit(QCA_IBS_DISABLED, &qca->flags)) {
			bt_dev_err(hu->hdev, "SSR or FW download time out");
			ret = -ETIMEDOUT;
```

`FW_DOWNLOAD_TIMEOUT_MS` is 3000, and the recorded abort measured 3.3 s. The
function already returns early for `QCA_ROM_FW` and for `QCA_BT_OFF`; a
controller that was never opened deserves the same treatment, since there is no
in-band sleep to negotiate.

The consequence is out of proportion to the fault: one never-initialised
Bluetooth controller stops the entire machine from suspending.

## What this does not fix

Neither patch makes the controller initialise. They stop a dead controller from
panicking the kernel on unload and from aborting system suspend — which also
unblocks the control experiment the earlier note could not run, since
`rmmod hci_uart` was the way to test whether Bluetooth was the only thing
aborting the cycle.

Root-causing the initialisation failure itself still needs the phone.
