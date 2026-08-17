# Suspend/resume: one hypothesis closed, four defects opened

Date: 2026-08-17

## Status

Suspend/resume remains broken. The `ipa-clock-query` hypothesis carried over
from 16 August is refuted. A real `s2idle` cycle now completes and returns, but
the modem raises its watchdog while the AP is still asleep, and several
subsystems fail to come back correctly.

## Refuted: the IPA clock-query hypothesis

The 16 August session concluded that the MPSS watchdog after resume was caused
by the SMP2P `ipa-clock-query` interrupt being masked during suspend, and built
candidate `#183` to keep that interrupt enabled. The candidate was never
tested; the phone became unbootable before the test ran.

The change lives entirely in `ipa.ko`, so no rebuild or flash was required to
test it: the module built on 16 August
(`afddbab2f9ac9d5885186a3fabf4ec7307b2d9054f160e8b1e35c85d2934cf6c`) was already
installed and loaded.

A first cycle with IPA runtime-suspended and `rmnet_ipa0` down slept 61.7
seconds and produced no watchdog, but that result is void: the IPA was not
engaged. Repeating with `power/control=on` and `rmnet_ipa0` up reproduces the
failure exactly:

```text
[1110.152] PM: suspend entry (s2idle)
[1110.701] PM: suspend exit
[1111.300] qcom_q6v5_pas 4080000.remoteproc: watchdog received: SFR Init: wdog or kernel error suspected.
[1111.300] remoteproc remoteproc1: crash detected in modem: type watchdog
[1111.751] remoteproc remoteproc1: remote processor modem is now up
```

That cycle was truncated to 0.55 s, so the watchdog appeared to follow the
resume; the unplugged measurement below shows it actually fires during the
sleep. Decisively, the `ipa-clock-query` interrupt counter reads **0 both
before and after** the cycle, with IPA active. The modem never issues a clock
query at all, so the mechanism the patch protects does not occur. The
hypothesis is not merely ineffective, it describes an event that does not
happen.

The modem recovers on its own (`crash #1`, then `modem is now up`), so this is
reproducible on demand and non-destructive.

## Watchdog timing: unresolved, and printk timestamps cannot settle it

An earlier revision of this file claimed the watchdog fires 4.46 s *into*
s2idle and therefore that this is a suspend defect rather than a resume
defect. That claim is withdrawn: it was derived from `dmesg` timestamps, and
those do not measure sleep on this platform.

Measured directly, with markers written to `/dev/kmsg` either side of a cycle:

```text
delta wall clock   = 21 s
delta /proc/uptime = 21.15 s
MARQUEUR-AVANT [339.549985]
MARQUEUR-APRES [340.332915]   -> 0.78 s of printk time
```

The printk clock freezes across `s2idle` while the monotonic clock keeps
running, so any duration derived from `dmesg` across a suspend is wrong by
whatever the sleep lasted.

What survives is message *ordering*, which is unaffected by the clock scale,
and it is not consistent between runs:

| run | watchdog logged |
|---|---|
| unplugged, IPA forced active | before `PM: suspend exit` |
| plugged, IPA in autosuspend, 3 cycles | after `PM: suspend exit`, ~0.79 s later |

So the watchdog is not reliably on one side of the resume boundary, and the
question of where in the cycle the modem dies is open. Settling it needs a
timebase that survives suspend: `/proc/uptime` sampling around the cycle, or
the modem's own SFR timestamp, not kernel log timestamps.

## Cycle truncation is caused by the modem, not the charger

An earlier reading blamed the SMB5 charger for cutting `s2idle` to 0.55 s,
based on its wakeup-source count while attached to host USB. The unplugged run
refutes that:

| cycle | charger | sleep length | preceded by |
|---|---|---|---|
| plugged | attached | 0.55 s | normal operation |
| unplugged 1 | detached | 34.2 s | normal operation |
| unplugged 2 | detached | 0.571 s | modem crash + recovery |

Unplugged cycle 2 is truncated just as badly as the plugged cycle, so the
charger is not the discriminating factor. What separates the two unplugged
cycles is that the second follows a modem crash and its automatic recovery.
The modem state, not the charger, governs whether the AP can stay asleep.

`rtcwake -m mem -s N` does not arm the alarm on this device. Writing
`/sys/class/rtc/rtc0/wakealarm` directly does, and the value must be read back
and verified before entering suspend.

## Defect 1: Wi-Fi does not survive resume

```text
ath10k_snoc 18800000.wifi: failed to send qmi config: -110
ath10k_snoc 18800000.wifi: failed to enable wcn3990: -110
ath10k_snoc 18800000.wifi: Could not init hif: -110
Hardware became unavailable upon resume.
WARNING: CPU: 1 PID: 249 at net/mac80211/util.c:1818 ieee80211_reconfig+0x480/0x10c4 [mac80211]
```

Reproduced unplugged, so it is not an artefact of the charger. `wlan0` goes
from `UP` to `DOWN` across the cycle and stays down.

The controller is not left in an unrecoverable state: `rmmod ath10k_snoc`
followed by `modprobe ath10k_snoc` brings it back, reloads the firmware and
reassociates without a reboot. Note that the reload also re-triggers
`invalid MAC address; choosing random`, so the station address and the DHCP
lease change each time. The driver's resume path, not the hardware, is what
fails.

## Defect 2: camera CCI fails to restore its clock

```text
cci_resume+0x3c/0x80 [i2c_qcom_cci]
Failed to enable clk 'camnoc_axi': -16
```

`-EBUSY` on `camnoc_axi` during `cci_resume`. Seen on the truncated cycles but
not on either unplugged cycle, so it is not systematic. This is adjacent to the
`lc898217xc` synchronous-resume change made on 16 August.

## Defect 3: the elogind session is not reactivated

This is the defect users actually hit: after resume the touchscreen and the
power button both stop working, while the display and USB return normally.

The cause is not the touch controller. The graphical session on `seat0` comes
back inactive and stays there:

```text
session c1  Seat=seat0  Active=no   State=online
```

logind grants input devices only to an active session, so `kwin_wayland` holds
no `/dev/input/event*` at all — hence losing touch and the power key together.
`loginctl activate c1` restores it immediately and `kwin` reopens `event0`,
`event2`, `event3` and `event4`.

## Defect 4: S6SY761 sensing is not re-enabled on resume

Independent of defect 3, and a genuine upstream driver bug.

`s6sy761_suspend()` powers the controller down, clearing its sensing state.
`s6sy761_resume()` powers it back up and re-enables the interrupt but never
re-issues `S6SY761_SENSE_ON`, which is only sent from `s6sy761_input_open()`.

Measured after a resume cycle, with the device left open:

| | interrupts | event bytes |
|---|---|---|
| before `SENSE_ON` | 2 over 25 s | 0 |
| after manual `SENSE_ON` over i2c | 1137 over 20 s | 75744 |

Note the 16 August `s6sy761` change removed the logged `-ENODEV` at resume, and
that part holds — no `-ENODEV` appears now. But the touchscreen still delivered
no events afterwards, because nothing verified function after the log went
quiet.

In this stack the bug is usually masked: logind revokes and regrants the device
around a sleep, so `input_close()`/`input_open()` re-send `SENSE_ON`. It bites
whenever something keeps the input device open across the sleep.

Fixed by `Input: s6sy761 - re-enable sensing on system resume`.

## Not reproduced on the unplugged run

Two defects recorded earlier did not appear on either unplugged cycle:
`cci_resume` reported no `camnoc_axi` failure, and the elogind session stayed
`Active=yes` across both cycles, so no input was lost. Neither is therefore
systematic; both depend on a prior state that has not yet been isolated.


## The suspend cycle is aborted by the Bluetooth driver

A single cycle from a clean boot, with no prior modem crash, shows the actual
failure for the first time. Earlier runs buried it under accumulated state.

```text
[122.220] PM: suspend entry (s2idle)
[125.521] Bluetooth: hci0: SSR or FW download time out
[125.521] hci_uart_qca serial0-0: PM: dpm_run_callback(): qca_suspend [hci_uart] returns -110
[125.522] hci_uart_qca serial0-0: PM: failed to suspend: error -110
[125.657] PM: Some devices failed to suspend, or early wake event detected
[126.165] PM: suspend exit
[131.556] qcom_q6v5_pas 4080000.remoteproc: watchdog received: SFR Init
```

`qca_suspend()` times out after roughly 3.3 s and the whole cycle is abandoned:
measured sleep was 3.9 s against a 20 s alarm. The modem watchdog follows the
aborted cycle rather than preceding it.

The controller is dead from boot: `hci0` is `DOWN` with a locally administered
address `02:00:97:A6:3F:B2`, meaning no firmware was ever downloaded, and 13
Bluetooth errors are logged before the first suspend is attempted.

This reframes the modem watchdog as a probable consequence of a half-completed
suspend rather than an independent defect, and it explains the truncated
cycles that were previously blamed on the charger and then on modem state.
It is not yet proven: removing Bluetooth to confirm has not been achieved, see
below.

## Removing hci_uart panics the kernel

Attempting to unload the driver to run the control experiment crashed the
device. The `oops=panic` command line turned it into a panic and the platform
rebooted.

```text
Internal error: Oops: 0000000096000005 [#1] SMP
Comm: rmmod
pc : tty_set_termios+0x28/0x3dc
lr : ttyport_set_baudrate+0x74/0xa0
Call trace:
  tty_set_termios
  ttyport_set_baudrate
  serdev_device_set_baudrate
  qca_power_shutdown           [hci_uart]
  qca_serdev_remove            [hci_uart]
  serdev_drv_remove
  device_release_driver_internal
  driver_unregister
  qca_deinit                   [hci_uart]
  __arm64_sys_delete_module
Kernel panic - not syncing: Oops: Fatal exception
```

`qca_power_shutdown()` calls `serdev_device_set_baudrate()` on a port whose tty
is already gone. This is a second, independent bug in the same driver, and it
blocks the obvious way of testing the first one. A control experiment must
instead blacklist the module at boot.

The full log is kept at
`build/2026-08-17-modem-dumps/ramoops/panic-rmmod-hci_uart.txt`. It carries
single-bit corruption because this ramoops region has no ECC.

## Two further defects seen in the suspend path

```text
dwc3-qcom-legacy a6f8800.usb: port-1 HS-PHY not in L2
geni_i2c 884000.i2c: error turning SE resources:-13
oneplus-hotdog-popup-motor camera-popup: automatic open failed (-13), close recovery failed (-13)
```

The camera pop-up motor driver issues i2c transactions during suspend after the
GENI controller has released its resources, failing with `-EACCES` on both the
operation and its recovery path. The USB PHY does not reach L2.


## The modem dies 4.4 s into the sleep, and it is deterministic

Arming the watchdog interrupt as a wakeup source removed the last measurement
ambiguity. The interrupt is no longer masked for the duration of the cycle, so
its arrival time is the time the modem actually failed.

```text
[50.267] PM: suspend entry (s2idle)
[54.698] qcom_q6v5_pas 4080000.remoteproc: watchdog received: SFR Init
[84.054] PM: suspend exit
```

The modem raises its watchdog roughly 4.4 s after suspend entry, while the
application processors are still asleep. The system does not abort s2idle on
it: the crash is handled, the modem is recovered, and the sleep continues.

Eight consecutive `pm_test=devices` cycles in a fixed configuration produced a
watchdog on all eight, so the failure is deterministic and cheap to reproduce.

Two things follow from the timing. The device suspend callbacks all complete in
324 ms, so nothing that runs at 4.4 s is a callback: the modem is timing out
waiting for something rather than reacting to an event. And the ADSP, which is
suspended under exactly the same conditions, never raises its watchdog
(`q6v5 wdog` for lpass stays at zero), so this is specific to the modem.

The consistent 4.4 s and the strings recovered from the ramdump
(`FATAL: LARGE ISLAND ENTRY LATENCY DETECTED`, `USLEEP FATAL ERROR CALLED`)
point at the modem failing its own low-power entry rather than being starved of
a service. That remains a hypothesis: those strings are format templates in the
firmware image and were not observed as emitted messages.

## Eliminated by measurement

| hypothesis | how it was refuted |
|---|---|
| userspace freeze starves rmtfs and friends | `pm_test=freezer` is clean over 5 s and 15 s |
| deep cpuidle collapses a rail the modem needs | watchdog on all 3 cycles with `cpu-sleep-0-0` disabled |
| the charger truncates the cycle | a plugged cycle slept 33.8 s |
| `rmnet_ipa0` being up is required | watchdog reproduces with the interface down |
| forcing IPA runtime-active is required | watchdog reproduces with IPA in normal autosuspend |
| the IPA suspend stub from 16 August | reverting to upstream behaviour changes nothing |


## What the modem death is not

With the watchdog interrupt armed as a wakeup and the alarm verified before
every cycle, each candidate below was removed and the cycle repeated. The
modem watchdog survived all of them.

| removed | sleep length | watchdog |
|---|---|---|
| nothing (reference) | 55.9 s | yes |
| `ath10k_snoc` (Wi-Fi) | 26.2 s | yes |
| `ath10k_snoc` + `hotdog_popup_motor` | 26.3 s | yes |
| `hci_uart` (Bluetooth, blacklisted at boot) | full cycle | yes |
| `lc898217xc` + pop-up motor | 5 s gate | yes |
| deep cpuidle disabled | 5 s gate | yes, 3/3 |

Both radios on the WCN3990 are therefore ruled out for the modem crash, as are
the camera actuator, the pop-up motor and the CPU idle state. Every Qualcomm
driver in soc, rpmsg, remoteproc and interconnect was also checked for system
suspend callbacks: there are none, so nothing in that stack acts at suspend.

After all removals the last message before the crash is
`dwc3-qcom-legacy a6f8800.usb: port-1 HS-PHY not in L2`, 1.1 s ahead of the
watchdog.

## Wi-Fi explains the slow wake, and the pop-up motor explains the i2c errors

Two side findings that stand on their own.

Removing `ath10k_snoc` halves the cycle: 55.9 s with it, 26.2 s without, against
a 25 s alarm. The extra 30 s is `ath10k` timing out on resume
(`failed to send qmi mode: -110`, `Could not init hif: -110`). That is the
delay a user feels when waking the phone after a long sleep.

Removing `hotdog_popup_motor` removes the
`geni_i2c 884000.i2c: error turning SE resources:-13` pair and the motor's own
`-EACCES` failures from the suspend path. Those errors come from that driver
issuing i2c transactions after the GENI controller has released its resources.

## The crash happens once per suspend entry, not continuously

A real 2.5 hour sleep produced exactly one modem crash, 4.6 s after suspend
entry, after which the modem recovered and stayed up for the rest of the sleep.
Short repeated cycles produce one crash each. So the failure is bound to the
transition into sleep, not to the suspended state itself, and the phone does
sleep and wake correctly apart from it.


## Why Wi-Fi never comes back, and what fixing it needs

Wi-Fi loss after resume is a consequence of the modem crash, through two
distinct failures.

**Stale MSA ownership.** `ath10k_qmi_map_msa_permission()` always asks the
hypervisor to move the MSA regions away from HLOS, but those regions are also
assigned to `MSS_MSA`, and a modem restart returns them without the WLAN side
being told. The next assignment is rejected:

```text
qcom_scm firmware:scm: Assign memory protection call failed -22
ath10k_snoc 18800000.wifi: failed to assign msa map permissions: -22
```

Reclaiming the region and retrying once removes this failure; after the change
no `-22` appears on any cycle.

**Recovery races the modem restart.** This is the one that still breaks Wi-Fi.
The WLAN firmware goes down with the modem, and the resume path tries to bring
it back while the modem is still restarting, so every QMI exchange times out:

```text
71.653  ath10k_snoc: failed to send qmi mode: -110
71.653  ath10k_snoc: failed to enable wcn3990: -110
71.653  ath10k_snoc: Could not init hif: -110
71.792  ath10k_snoc: firmware crashed!
72.218  ipa 1e40000.ipa: received modem running event      <- modem only up here
```

Reloading `ath10k_snoc` by hand once the modem is up always restores Wi-Fi, so
the hardware and firmware are fine; only the ordering is wrong.

An attempt to fix this from the modem SSR notifier, by deferring recovery to
`QCOM_SSR_AFTER_POWERUP`, was written and reverted. It fires at the right
moment but cannot work from there:

```text
72.230  ath10k_snoc: cannot restart a device that hasn't been started
```

`ath10k_core_start_recovery()` requires a started device, and by then the
resume attempt has already failed and left it unstarted. The fix has to keep
the resume path from failing in the first place, or re-enter the QMI bring-up
rather than the recovery path. That needs a closer look at how the WLAN QMI
server re-arrives after a modem restart.


## The application processor holds nothing the modem needs

The modem node carries one power domain the ADSP does not:

```text
modem : power-domains = <&rpmhpd SM8150_CX>, <&rpmhpd SM8150_MSS>
adsp  : power-domains = <&rpmhpd SM8150_CX>
```

That asymmetry looked like it could explain why the modem dies at suspend and
the ADSP does not, but the live state rules it out. After the PAS handover the
application processor has released everything:

```text
mss    off-0    performance 0
    genpd:1:4080000.remoteproc    suspended    0    SW
cx     off-0    performance 0
```

The modem is running while the AP's votes for both `CX` and `MSS` sit at zero,
because past handover the modem drives its own resources through its own RPMh
master. So suspending the AP cannot withdraw power, clocks or corners from the
modem: there is nothing left to withdraw.

Together with the earlier results this closes the AP-side search. The freeze is
harmless, no Qualcomm driver acts at suspend, every removable driver has been
removed, the CPU idle state is irrelevant, and the AP holds no resources on the
modem's behalf. What remains is the contract between the two: mainline never
tells the modem that the application processors are going to sleep, and the
outbound SMP2P channel that downstream uses for exactly that carries only the
"stop" bit here.

## Current gate

Two defects remain in the way of a clean cycle.

The modem raises its watchdog 4.4 to 4.6 s into every suspend entry. Every
AP-side candidate tried so far has been eliminated, and mainline has no
AP-to-modem sleep notification at all: the outbound SMP2P channel exists
(`modem_smp2p_out`) but only bit 0 is used, for "stop". Downstream Qualcomm
carries a sleepstate driver that toggles a bit around suspend. That gap is the
most plausible remaining explanation and the next thing to investigate.

Wi-Fi does not survive resume and has to be reloaded, which also costs about
30 s of wake latency.

The natural suspect is what the AP stops servicing once asleep — GLINK, SMP2P,
RPM votes or a shared resource the MPSS firmware expects to remain available.
The next useful measurement is the state of the modem links immediately before
suspend entry, and identification of what the modem is waiting on inside that
4.5 second window.
