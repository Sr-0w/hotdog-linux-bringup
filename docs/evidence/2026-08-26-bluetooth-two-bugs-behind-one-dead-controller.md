# Bluetooth: two driver bugs behind one dead controller

Date: 2026-08-26

The README lists the controller lifecycle as Broken: `hci0` stays `DOWN` with a
locally administered address, `qca_suspend()` aborts every system suspend, and
`rmmod hci_uart` panics. The phone was unavailable, so this is source and
firmware analysis against the traces already recorded in
[suspend/resume defects](2026-08-17-suspend-resume-defects.md). The phone came
back later and the last two sections are hardware-validated; everything before
them was written blind.

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

Root-causing the initialisation failure itself still needs the phone -- and
the next section is what that turned up.

## The actual root cause, found afterwards and validated

Neither driver bug explained why the controller never came up. That answer was
one line earlier: the UART it hangs off never probed.

```
qcom_geni_serial c8c000.serial: Invalid line -19
```

`-19` is `-ENODEV` from `of_alias_get_id()`. `qcom_geni_serial_probe()` takes
its line number from an alias, trying `serial` then `hsuart`, and the board
declared neither — `/aliases` held only `display0`. So there was no `ttyHS`, no
serdev child under `serial@c8c000`, and no device for `hci_uart` to bind. `hci0`
down with a locally administered address and no firmware download is exactly
what that looks like from userspace.

The alias was never present, on this branch or on `main`. This is not a
migration regression; it was never fixed. `sm8150-google-flame`,
`sm8150-xiaomi-nabu` and `sm8150-xiaomi-raphael` all declare
`hsuart0 = &uart13` for the same UART.

## Hardware validation, r13

```
c8c000.serial: ttyHS0 at MMIO 0xc8c000 (irq = 134, base_baud = 0) is a MSM
/sys/bus/serial/devices/: serial0  serial0-0

Bluetooth: hci0: QCA Product ID   :0x0000000a
Bluetooth: hci0: QCA SOC Version  :0x40010224
Bluetooth: hci0: QCA Downloading qca/crbtfw21.tlv
Bluetooth: hci0: QCA Downloading qca/crnv21.bin
Bluetooth: hci0: QCA setup on UART is completed

hci0: Type: Primary  Bus: UART   UP RUNNING
      RX bytes:4077 events:249 errors:0
      TX bytes:725008 commands:3021 errors:0
```

The firmware downloads, which is the step that never happened before.

The two driver fixes were exercised on the now-healthy path:

- A full `s2idle` cycle completed — `PM: suspend entry` then `PM: suspend exit`
  with no `failed to suspend`, no `qca_suspend returns -110` and no `SSR or FW
  download time out`. Bluetooth no longer aborts system suspend.
- `rmmod hci_uart` returned 0, unloaded cleanly and removed `hci0`, with the
  boot ID unchanged: no panic, where it previously oopsed in
  `tty_set_termios()`.

Note that with the controller healthy the port is open, so both fixes take
their normal path. What is proven is that they do not regress a working
controller, and that the crash and the suspend abort are gone. Their guards
still matter for any future boot where setup fails.

## Still open

Reloading the module does not restore the controller: after `rmmod` plus
`modprobe hci_uart` the protocol registers but no `hci0` appears, and binding
`serial0-0` to `hci_uart_qca` by hand hangs. Bluetooth is only healthy from a
cold boot so far. Scanning and pairing are not validated.

The BD address is still locally administered, `02:00:97:A6:3F:B2`; the factory
address lives outside the NVM and remains a separate problem.

## Scan, pair and input, validated end to end

2026-08-27, `r13`, after a clean `fastboot reboot`.

An LE scan lists nearby devices, and the owner's controller answers at -39 dBm:

```
Device 28:EA:0B:CC:4D:28 Xbox Wireless Controller
```

Pairing has to happen inside one `bluetoothctl` session: each separate
invocation is its own session, so the discovery cache is gone by the time
`pair` runs and the device reads as "not available". Held in one session, with
scanning still on:

```
Pairing successful
Name: Xbox Wireless Controller
Paired: yes   Trusted: yes   Connected: yes
hcitool con: LE 28:EA:0B:CC:4D:28 handle 1 state 1 lm CENTRAL AUTH ENCRYPT
```

The link is authenticated and encrypted, and the kernel creates the input
device:

```
N: Name="Xbox Wireless Controller"
/dev/input/js0
```

Reading that node while the owner moved the sticks gave **2484 real events**
against 23 init events -- axes 0, 1 and 3 -- with `errors:0` on both directions
of the HCI counters. Bluetooth is Working: scan, pair, encrypted link, HID
input.

What stays open is unchanged: reloading `hci_uart` does not bring `hci0` back,
and the address is still locally administered.

## The two items left open, resolved and characterised

**Module reload.** Not reproducible. Three consecutive `rmmod hci_uart` /
`modprobe hci_uart` cycles each recreated `hci0`, rebound `serial0-0` to
`hci_uart_qca` and re-ran the firmware download, and the paired controller
reconnected by itself:

```
microsoft 0005:045E:0B13.0002: input,hidraw0: BLUETOOTH HID v5.23 Gamepad
    [Xbox Wireless Controller] on 02:00:97:a6:3f:b2
```

The single earlier failure — no `hci0`, and a manual bind that hung — happened on
the boot where sshd also never started, after a chain of unclean busybox
reboots. It belongs to that degraded boot, not to the driver.

**The address.** It is not recoverable on this handset, and the reason is
structural rather than a port defect.

The QCA NVM carries the BD address as a six-byte TLV, and it is all zeros in
*both* the community `crnv21.bin` and the one from OxygenOS 11.0.9.1 — the
factory value is provisioned per unit, not shipped in firmware. On this phone
that provisioning is empty: `/persist/wlan_mac.bin` and
`/persist/qca6390/wlan_mac.bin` are both 0 bytes, no `bdaddr`/`MacAddress`
record appears anywhere in `persist`, `devinfo`, `opproduct`, `oem_stanvbk`,
`oem_dycnvbk`, `fsg`, `modemst1` or `modemst2`. Wi-Fi shows the same symptom
from the same gap — `ath10k: invalid MAC address: choosing random`.

What we have instead is serviceable: `02:00:97:A6:3F:B2` is stable across
reboots and across module reloads, so pairings persist, and `btmgmt info`
reports `missing options:` empty — BlueZ does not consider the controller
unconfigured.

If the factory value is ever recovered, applying it needs no kernel change:
`hci_qca` sets `hdev->set_bdaddr`, so `btmgmt public-addr <ADDR>` is enough, and
`btmgmt info` already lists `public-address` under supported options.
