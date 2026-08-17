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

## Current gate

The blocking item is the MPSS watchdog. It reproduces on every cycle where the
modem is running, including with IPA left in normal autosuspend, so it is not
an artefact of forcing IPA active. Its position relative to resume is not yet
established, see above.

The natural suspect is what the AP stops servicing once asleep — GLINK, SMP2P,
RPM votes or a shared resource the MPSS firmware expects to remain available.
The next useful measurement is the state of the modem links immediately before
suspend entry, and identification of what the modem is waiting on inside that
4.5 second window.
