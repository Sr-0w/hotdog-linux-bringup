# Suspend/resume: one hypothesis closed, four defects opened

Date: 2026-08-17

## Status

Suspend/resume remains broken. The `ipa-clock-query` hypothesis carried over
from 16 August is refuted. A real `s2idle` cycle now completes and returns, but
four distinct subsystems fail to come back correctly, and the test methodology
itself was found to be confounded by the charger.

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

The watchdog fires 0.6 s after resume, matching the 0.79 s signature recorded on
16 August. Decisively, the `ipa-clock-query` interrupt counter reads **0 both
before and after** the cycle, with IPA active. The modem never issues a clock
query at all, so the mechanism the patch protects does not occur. The
hypothesis is not merely ineffective, it describes an event that does not
happen.

The modem recovers on its own (`crash #1`, then `modem is now up`), so this is
reproducible on demand and non-destructive.

## Confounder: the charger aborts s2idle

The cycle above slept for 0.55 s despite an RTC alarm armed at 25 s. Wakeup
source accounting explains it:

```text
pm8150b-charger                 active_count=78
c440000.spmi:pmic@0:rtc@6000    active_count=46
4080000.remoteproc              active_count=1   max_time=450ms
```

The SMB5 charger raises wakeup events continuously while the phone is attached
to host USB, cutting `s2idle` short. This matters retroactively: the entire
16 August suspend campaign ran on a phone plugged in and charging, so its cycles
were being truncated to fractions of a second rather than exercising a real
sleep. Results from that campaign should be re-read with that in mind.

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

## Defect 2: camera CCI fails to restore its clock

```text
cci_resume+0x3c/0x80 [i2c_qcom_cci]
Failed to enable clk 'camnoc_axi': -16
```

`-EBUSY` on `camnoc_axi` during `cci_resume`, reproducible on every cycle. This
is adjacent to the `lc898217xc` synchronous-resume change made on 16 August.

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

## Current gate

The blocking item is the MPSS watchdog with IPA active. The next useful
measurement is a cycle with the USB cable detached, so that `s2idle` runs for
its full duration instead of aborting in half a second, to establish whether the
watchdog is a genuine resume defect or an artefact of truncated cycles.
