# Suspend/resume: one hypothesis closed, four defects opened

Date: 2026-08-17

## Status

Suspend/resume is not usable. The phone does sleep and wake, but the modem
raises its watchdog on entering suspend, and everything else a user notices
follows from that.

This file grew through a long investigation and records refuted hypotheses as
well as confirmed ones, including several of the author's own that measurement
knocked down. Read this summary for the current position; the sections below
are the working record, in order, and some of them are superseded by later ones.

**Retracted on 2026-08-18, and it runs through most of this file.** The
island-entry attribution has no evidence behind it. It came from finding
`FATAL: LARGE ISLAND ENTRY LATENCY DETECTED` with `strings` on the modem
ramdump. That same string is present in `modem.mbn`, the stock firmware image
as shipped and never executed, so it is a format string in the firmware's
string table and not a logged event. A `strings` sweep of a memory dump returns
the loaded code and rodata along with the data. Every section below that
reasons about a latency budget, a hard deadline or a first-entry-after-
transition rests on that artefact; treat those conclusions as unsupported.

**What is established**

- The modem raises its own watchdog 3.7 s to 9.2 s after the AP enters
  `s2idle`, measured from `PM: suspend entry` to `watchdog received` in the
  same `dmesg` (both endpoints are on the same side of the clock freeze, so
  this delta is sound where the retracted ones were not). Three cycles: 4.53 s,
  3.7 s, 9.2 s.
- The SFR the modem writes to SMEM is `Init: wdog or kernel error suspected`.
  That is the generic reason the Q6 records when its watchdog bites without a
  more specific fault, i.e. the task that pets the watchdog stopped being
  scheduled. It indicates a hung or starved modem thread, not a latency
  complaint.
- The AP never reaches system-level low power at all: `qcom_stats` reports
  `aosd`, `cxsd` and `ddr` at `Count: 0` since boot, and `cpuidle` exposes only
  `WFI` and `cpu-sleep-0-0`. With no system state there is no `rpmh_flush()`
  and no sleep-set application, so that whole family of hypotheses is excluded
  by construction rather than by testing.
- The modem survives the sleep in the sense that it dies *during* it and the AP
  keeps sleeping afterwards: in `s2idle` the watchdog IRQ is serviced without
  ending the suspend, which is why the handler's `dmesg` line falls inside the
  sleep window.
- The Bluetooth driver aborts every cycle before this can even be reached:
  `qca_suspend()` returns `-110`. With `hci_uart` blacklisted the cycle
  completes.
- The ADSP survives identical cycles; only the modem dies. Both are PAS
  remote processors started the same way, so whatever the AP withdraws is
  something only the modem depends on.

**What causes the user-visible symptoms**, all downstream of the modem crash

- Slow wake: one `ath10k` QMI transaction burning its full 30 s timeout with no
  modem to answer. Measured directly with `power:device_pm_callback_*`:
  `ieee80211 phy0 [resume]` takes 30.371 s, and no other callback in the cycle
  exceeds 0.18 s.
- Wi-Fi never returning: **fixed, and measured.** Four suspend cycles each
  ending in a modem watchdog crash now leave `wlan0` up with its address
  through all four; every one of them used to leave it down. It took two
  patches, and the first one alone did nothing.

  `ath10k_qmi_map_msa_permission()` moves the regions from HLOS to `MSS_MSA`
  and `WLAN`, so it only succeeds while HLOS owns them, and the reclaim that
  restores that ownership hung off the WLFW service leaving QRTR, which a
  crashing modem does not reliably produce. `reclaim the MSA regions when the
  modem goes down` moves it to the subsystem restart notifier on
  `QCOM_SSR_AFTER_SHUTDOWN`, the one point where the modem is known to be
  down, and tracks the assignment so either path can reach it first.

  That ran at the right moment and was still rejected with `-EINVAL`, because
  `qcom_scm_assign_mem()` validates the source set against the actual owners
  and tearing the modem down revokes its `MSS_MSA` share silently.
  `reclaim MSA from whoever still owns it` retries with the `WLAN` set alone.
  Together they clear every assignment and QMI configuration failure. One
  crash in four still logs the reclaim error twice: that is the case where
  HLOS already holds the regions, and the assignment after it succeeds.
- Platform resets: modem crash, then MSA failure, then a DPU frame-done
  timeout that ends the boot.

**A defect this investigation introduced**, recorded because it polluted the
measurements taken while it was in the tree. The local patch "recover the MSA
assignment after a modem restart" answered a rejected assignment by reclaiming
the regions to HLOS and retrying. `ath10k_qmi_unmap_msa_permission()` moves
them out of `MSS_MSA`, so it strips a *running* modem of its own memory. A
pstore capture shows the modem taking a fatal error 77 ms later, and the
recovery that follows assigns the regions again, so each restart fed the next.
Reverted. Upstream already reclaims the regions from
`ath10k_qmi_event_server_exit()`, which runs while the modem is down.

**The measurement protocol, and why the earlier ones were not good enough.**
`/sys/power/pm_test` runs the suspend phases up to a chosen level, waits five
seconds and returns by itself: no RTC alarm to arm, no wake that can fail to
arrive, fixed duration, about twenty seconds per cycle. It is in
`helpers/suspend-pm-test-cycle.sh`. Count the modem watchdog interrupt in
`/proc/interrupts` rather than reading `dmesg`, whose timestamp belongs to the
threaded handler.

The failure is probabilistic, near 2 in 3. A first run gave freezer 0/2,
devices 2/2, platform 2/2, and a later one gave 2/3 unmodified and 1/3 with
IPA removed. Those last two do not differ. **At p close to 0.6, three cycles
distinguish nothing and two cycles clean happen once in six runs by chance.**
Every elimination recorded below that rests on one or two cycles is worth no
more than that, including the freezer/devices split above, and the ones taken
on full `s2idle` cycles are worse still because that protocol was also noisy.
Configurations need on the order of ten cycles each before they can be
compared at all.

**Only interleaved comparisons are worth anything.** Two runs of
`pm_test=devices` on identical code gave 2/10 and 13/15. The rate swings that
far between runs, so no configuration may be compared against a figure from an
earlier run, however many cycles each has. An attempt to read the 2/10 as the
MSA revert lowering the failure rate was withdrawn for exactly this reason.
Alternate the configurations within a single run instead, so that whatever
drifts over a series, heat or the modem's state after N restarts, lands on both
of them equally.

**The phase is settled.** Thirty cycles alternating the two levels one for one:

| level | modem watchdog |
| --- | --- |
| `freezer` | 2/15 |
| `devices` | 13/15 |

The killer is in `dpm_prepare` plus `dpm_suspend`, the ordinary `->suspend()`
callbacks. Freezing userspace on its own is close to clean; the residual 2/15
is consistent with a crash from the preceding `devices` cycle landing late.
This supersedes the earlier freezer 0/2 against devices 2/2, which at this
failure rate showed nothing, and it is the one localisation in this file backed
by a sample large enough to carry it.

**The display path is cleared.** Forty cycles alternating blocks with the
panel lit and blanked: 15/20 lit against 14/20 blanked. `msm_dpu` was the
obvious suspect, being the only `->suspend()` callback in the cycle that takes
longer than 0.01 s, at 0.160 s, and the one that drops the `mmcx` corner.
Blanking really did take effect rather than being swallowed by the compositor:
`initializing panel` appears ten times over the run, once per unblank. An
interim reading of 4/5 against 1/4 pointed the other way and was noise, which
is what the interleaved design is there to catch.

**What has been eliminated by measurement**, each with its cycle counts below

AP-to-modem traffic of any kind, QRTR client deletions, in-flight transactions,
power-domain or corner withdrawal, RPMh sleep-set programming, the SMP2P
interrupt being masked, deep CPU idle states, the charger, userspace freezing,
and every driver that could be removed at runtime: Bluetooth, Wi-Fi, USB, IPA,
`rmnet`, the camera actuator and the pop-up motor.

**What is not known**

What the modem is waiting on. The established facts narrow it: the Q6 stops
petting its watchdog a few seconds after the AP's devices are suspended, the
SoC never enters a system low-power state, and the ADSP under identical
conditions is fine. That points at a resource or a service the AP withdraws
during `dpm_suspend` which only the modem consumes, and at a modem thread
blocking on it long enough to starve the pet task. The next measurement is the
last AP-to-modem exchange before the watchdog, to see what goes unanswered.

**Two measurement traps** that produced retracted conclusions here, worth
knowing before adding to this file: `printk` timestamps freeze across `s2idle`,
so no duration may be derived from `dmesg` across a cycle; and instrumentation
changes the failure rate, so a clean cycle after removing a driver never proved
that driver responsible.

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


## The stock device tree refutes the sleep-notification hypothesis

The OxygenOS device tree is still on the phone, in `boot_a`, and it does carry
the sleepstate mechanism that mainline lacks:

```dts
qcom,smp2p_sleepstate {
        compatible = "qcom,smp2p-sleepstate";
        qcom,smem-states = <&sleepstate_out 0>;
        interrupt-names = "smp2p-sleepstate-in";
};
```

Resolving the phandles places both entries on a node with
`qcom,remote-pid = <0x03>`, that is the sensor DSP, with entry names
`sleepstate` and `sleepstate_see`. Nothing equivalent exists for the modem at
`remote-pid = <1>`.

So the stock firmware does not tell the modem that the application processors
are going to sleep either. Mainline is not missing a handshake the modem needs,
and the leading remaining hypothesis is refuted.

What the stock tree does carry, and mainline does not, is a separate component:

```dts
system_pm {
        compatible = "qcom,system-pm";
        mboxes = <&apps_rsc 0>;
};
```

Downstream this driver coordinates entry into sleep with RPMh over the RSC
mailbox, programming the sleep and wake vote sets and publishing the expected
wake time. Mainline covers the same ground differently, through `rpmh-rsc` and
the psci cpuidle domain. Comparing what each actually programs into the RSC is
the next avenue, and the last structural difference found so far.


## What the subsystem sleep counters show

`/sys/kernel/debug/qcom_stats` exposes each subsystem's low-power entries and
settles two questions at once.

Across a 56 s suspend that produced one watchdog:

```text
delta: modem=13  adsp=0  aosd=0  cxsd=0  ddr=0
```

The modem enters and leaves its own low-power state thirteen times while the
application processors sleep, and one of those transitions fails. The ADSP does
not transition at all, which is why it survives the same cycle: it never
attempts the manoeuvre that kills the modem. This fits the firmware strings
recovered from the ramdump, `LARGE ISLAND ENTRY LATENCY DETECTED` and
`USLEEP FATAL ERROR CALLED`. The modem is not being denied a service by the AP;
it is failing its own island entry.

The second result is independent and matters for the wider goal.
`aosd`, `cxsd` and `ddr` all stay at zero, on this cycle and since boot. The SoC
never reaches AOSS deep sleep, never collapses the CX rail and never puts DDR
into self-refresh, even during s2idle. Suspend as it stands therefore saves
very little power, which is consistent with the missing `qcom,system-pm`
coordination noted above: nothing programs the RPMh sleep sets that would let
those states be entered.

So there are two distinct problems behind "suspend does not work": the modem
fails its own low-power entry while the AP is asleep, and the AP's sleep never
reaches the states that would make it worth entering.


## The noirq phase is where the difference lies, but not through any interrupt tested

`pm_test=freezer` is clean over three consecutive cycles and `pm_test=devices`
fails on every one, so the failure lives in the device suspend phase. Within it
the `noirq` sub-phase is the only step that changes anything the modem can
observe, since no driver's suspend callback acts: it masks every interrupt not
marked `IRQF_NO_SUSPEND` or armed as a wakeup.

The two channels the modem uses are handled differently upstream:

```c
/* qcom_glink_smem.c, kept alive across suspend */
devm_request_irq(..., IRQF_NO_SUSPEND | IRQF_NO_AUTOEN, "glink-smem", smem);

/* smp2p.c, masked unless userspace opts in */
devm_request_threaded_irq(..., IRQF_ONESHOT, NULL, (void *)smp2p);
```

SMP2P is only wakeup-capable, disabled by default, with the driver leaving the
choice to userspace. Enabling it changes nothing:

| configuration | sleep | watchdog | modem island entries |
|---|---|---|---|
| reference | 56.4 s | yes | 13 |
| `smp2p-mpss` wakeup enabled | 56.4 s | yes | 13 |
| `ipa` module fully unloaded | 26.3 s | yes | 7 |

So the modem is not waiting on an SMP2P signal, and IPA is not involved at all,
which closes the last two candidates reachable at runtime. GLINK was already
correct, and neither `qcom_hwspinlock`, `llcc-qcom` nor `qcom_aoss` defines any
suspend callback.


## It is the first island entry after the transition that fails

The modem's own low-power counter refines the picture. Over a 56 s sleep it
records 13 entries, over a 26 s sleep 7, so roughly one every four seconds,
which is the same interval as the watchdog delay. Only one of them fails, and
the 2.5 hour sleep produced exactly one crash as well.

So the modem completes island entries perfectly well while the application
processors stay asleep. What it cannot survive is the first attempt after the
transition. The suspended state is not the problem; entering it is.

The natural explanation is an exchange left in flight when the AP suspends:
frozen userspace plus masked interrupts means a request the modem is waiting on
never completes, its island entry cannot proceed, and the latency guard fires.
After the crash the modem restarts with nothing outstanding, which is why the
following entries succeed.

Testing that by stopping the modem's userspace daemons cleanly does not work:
killing `rmtfs` crashes the modem immediately, before any suspend, and the
kernel then refuses to suspend at all with `Resource busy`. The modem depends
on rmtfs for its filesystem, so it can be frozen with its connection intact,
which it tolerates for at least 15 s, but not disconnected. Distinguishing the
two cases needs instrumentation of the QMI and GLINK traffic across the
transition rather than removing the daemons.


## Tracing settles it: the modem dies with no traffic at all

A kernel built with ftrace and the `qcom_glink`, `qcom_smp2p` and `qrtr`
tracepoints answers the in-flight-transaction question directly.

A 60 second control capture with the phone simply idle records **zero events**:
there is no background AP-to-modem traffic at all. A suspend cycle, by
contrast, showed a burst of IPCRTR exchanges with the modem and two
`qrtr_ns_message: del-client from 0:-2` right at the transition, which looked
like the trigger.

It is not. A later cycle recorded, between the markers:

```text
del-client pendant le cycle     : 0
echanges modem pendant le cycle : 0
WATCHDOG                        : 1
```

The modem raises its watchdog after a cycle in which the application processor
exchanged nothing with it whatsoever. No GLINK command, no QRTR message, no
SMP2P bit. That refutes the in-flight-transaction hypothesis and the QRTR
client-deletion hypothesis together, and it rules out communication as a cause
entirely: the modem is not waiting on the AP, because the AP said nothing.

The only SMP2P activity in the whole capture is the crash being reported at
resume:

```text
smp2p_notify_in: smp2p-mpss: slave-kernel: status:0x6 val:0x0
smp2p_ssr_ack:   smp2p-mpss: SSR detected
```

## A separate UFS failure, exposed by the instrumented kernel

The tracing kernel also surfaced a distinct and more dangerous defect. On one
resume the storage controller failed to leave its low-power link state:

```text
ufshcd-qcom 1d84000.ufshc: ufshcd_uic_hibern8_exit: hibern8 exit failed. ret = -110
ufshcd-qcom 1d84000.ufshc: ufshcd_ungate_work: hibern8 exit failed -110
[drm:dpu_encoder_frame_done_timeout:2715] [dpu error]enc33 frame done timeout
ufshcd-qcom 1d84000.ufshc: ufshcd_err_handler started; HBA state eh_fatal; link is broken
```

Losing the UFS link costs the rootfs and the platform resets, which is very
likely what left the phone stuck at an earlier boot with the USB gadget up and
no service listening. This kernel carries `CONFIG_FUNCTION_TRACER`, whose
instrumentation changes timing everywhere, so the failure may be provoked by
the instrument rather than latent. The diagnostic kernel is being rebuilt
without it to tell the two apart.


## Where the cycle time actually goes

`power:suspend_resume` gives the phase boundaries, and they change the picture
of what a "26 second sleep" has been measuring all along:

```text
52.457  suspend_enter begin
52.711  dpm_suspend begin
55.989  dpm_suspend end          -> 3.28 s
56.001  machine_suspend begin
56.002  timekeeping_freeze begin
56.002  timekeeping_freeze end
56.002  machine_suspend end
56.010  dpm_resume begin
86.504  dpm_resume end           -> 30.5 s
```

Suspending the devices takes 3.3 s and resuming them takes **30.5 s**. That
resume figure is on an unfrozen clock and is real: it is the wake latency a
user feels, and it is dominated by `ath10k` timing out, which matches the
earlier measurement that removing Wi-Fi halves the cycle.

The `machine_suspend` span cannot be read the same way. Timekeeping is frozen
between those two markers, so its apparent duration of a millisecond says
nothing about how long the phone actually slept. A cycle with a 25 s alarm
measured 25.4 s end to end on `/proc/uptime`, so the sleep does happen. An
earlier reading of this file claimed the system never sleeps at all; that was
the same frozen-clock mistake made twice, and it is withdrawn.

What does hold is `aosd`, `cxsd` and `ddr` staying at zero: s2idle runs, but
the SoC never reaches its deep states.

## A real charger interrupt storm, but not the modem's killer

Tracing the wakeup sources across a cycle shows the charger asserting one
every 11 ms while the suspend is being attempted:

```text
irq/149-usbin-i: wakeup_source_activate: pm8150b-charger state=0x420001
irq/149-usbin-i: wakeup_source_activate: pm8150b-charger state=0x430001
...
```

IRQ 149 is `usbin-icl-change`, the input-current-limit renegotiation. At idle
it fires zero times per second; suspending the USB controller makes the charger
renegotiate, and each step arms a wakeup. The limit also ends up at 800 mA
rather than the 900 mA negotiated earlier.

This is a genuine defect in the SMB5 path and worth fixing on its own, but it
is not the cause of the modem crash: disabling the charger's wakeup source
leaves the watchdog and the cycle duration unchanged.


## The reset cascade

Two platform resets during testing share one ending. The log stops immediately
after the same sequence:

```text
modem crashed event
ath10k_snoc: firmware crashed!
remoteproc remoteproc1: remote processor modem is now up
qcom_scm firmware:scm: Assign memory protection call failed -22
ath10k_snoc: failed to assign msa map permissions: -22
[drm:dpu_encoder_frame_done_timeout:2715] [dpu error]enc33 frame done timeout
```

The modem crash takes the WLAN firmware with it, the MSA reassignment fails,
and then the display pipeline misses a frame-done and the platform resets. The
DPU timeout is what actually ends the boot, which ties this back to the DSI
transport failures recorded separately.

A third reset earlier left the phone with the USB gadget answering pings but
no service listening, which fits a rootfs that never mounted after the UFS
hibern8 exit failure above.

Practical consequence for the method: real `s2idle` cycles risk the whole
platform, while `pm_test=devices` reproduces the modem watchdog in five seconds
without a real sleep, so without the UFS and DPU exposure. Tracing work should
use the latter.


## The failure is a timing race, not a fixed condition

The instrumented kernel changed the failure rate, which is itself the most
useful thing it produced.

On `#186`, without any tracing compiled in, `pm_test=devices` crashed the modem
on eight consecutive cycles. On `#188`, which carries ftrace, tracing and
dynamic debug, the same test gives a mix: two clean cycles, then one crash.
Enabling `device_pm_callback_start` tracing on top of that produced a clean
cycle as well.

Nothing about the modem, the devices or the suspend path changed between those
runs; only the amount of work the kernel does while suspending. So the modem
does not fail because of a condition that is either present or absent, it
fails a race, and slowing the suspend path down widens the window it needs.

That reframes what a fix would look like. It is not a missing handshake, a
withdrawn resource or an unanswered message, all of which have been ruled out
by measurement. It is an ordering or timing constraint inside the device
suspend phase that the modem's island entry depends on, and which mainline
happens to violate most of the time on this platform.

It also explains why every removal experiment came back negative: taking a
driver out changes the timing as much as it changes the configuration, so a
clean cycle after a removal never proved the removed driver was responsible.
Several of those results should be re-read as timing noise rather than
eliminations, which is why they are reported here with their cycle counts.


## The modem's own sleep machine, from the ramdump

The string table around `LARGE ISLAND ENTRY LATENCY DETECTED` describes the
firmware's low-power state machine and finally explains what the failure means:

```text
Set RPMh wakeup (match: 0x%llx)
Latency budget updated (Value: 0x%x)
Hard deadline (Expiry: 0x%llx, Type: %u, Obj: 0x%x)
Threshold set (Deadline: 0x%llx)
Begin island mgr entry
Kernel island entry canceled
Kernel island entry failure (Status: %d)
Island entry done
FATAL: LARGE ISLAND ENTRY LATENCY DETECTED
```

The modem computes a latency budget and a hard deadline for entering island
mode, and declares a fatal error when the entry overruns them. Crucially it
programs an **RPMh wakeup** as part of that entry, so its own sleep transition
depends on RPMh transactions completing in time.

RPMh is shared infrastructure: every master on the SoC arbitrates through it.
That gives a mechanism which fits every result gathered so far, including the
ones that refuted the earlier hypotheses:

- it needs no AP-to-modem traffic, and none was observed on the failing cycle;
- it needs no power vote to be withdrawn, and the AP holds none after handover;
- it needs no driver to act at suspend, and none does;
- it produces a fixed delay, because the deadline is fixed;
- it is sensitive to how long the AP stays in the suspended device state, which
  matches `freezer` being clean and `devices` failing;
- and it explains why the ADSP survives: the counters show the ADSP does not
  attempt a low-power transition during these cycles, while the modem attempts
  one every four seconds.

It also points at the one structural difference already identified between the
stock tree and mainline: `qcom,system-pm`, which downstream uses to coordinate
sleep entry with RPMh over the RSC mailbox, and which mainline has no
counterpart for on this platform.

That comparison was then made against the source, and it weakens the
hypothesis rather than confirming it.

The apps RSC on this platform does carry a `CONTROL_TCS`, so
`rpmh_rsc_write_next_wakeup()` is live and does write the maximum wakeup value
when `system_state == SYSTEM_SUSPEND`, where downstream's `system_pm` would
publish a real deadline. But that function is only reached from `rpmh_flush()`,
which is only called from the `cpu_pm` notifier, which only fires when the CPUs
actually enter idle.

Under `pm_test=devices` the kernel busy-waits with `mdelay`, so no `cpu_pm`
event occurs, nothing is written to the RSC at all, and the modem still dies.
If anything the AP leaving RPMh alone should make the modem's own transactions
faster, not slower.

So the sleep-set and wakeup programming are not what breaks the modem, and the
RPMh explanation only survives if the slowdown comes from somewhere other than
what the AP programs. The mechanism behind the modem's latency budget being
exceeded is still unidentified.


## The 30 second wake, exactly

`dpm_resume` measuring 30.5 s has a precise source in `ath10k`:

```c
#define ATH10K_QMI_TIMEOUT		30
ret = qmi_txn_wait(&txn, ATH10K_QMI_TIMEOUT * HZ);
```

Every QMI transaction waits up to thirty seconds. When the modem has just
crashed there is nothing to answer, so the transaction ath10k issues during
resume burns the whole timeout. That single wait is the wake latency, and it
matches the earlier measurement that removing `ath10k_snoc` halves the cycle.

The chain a user experiences is therefore fully accounted for except its first
step:

1. the suspend kills the modem, mechanism still unknown;
2. the modem crash takes the WLAN firmware with it;
3. resume issues a QMI exchange with no one to answer and waits 30 s, which is
   the slow wake;
4. the MSA reassignment then fails and Wi-Fi stays down until the module is
   reloaded.

Steps 2 to 4 are all consequences. Fixing step 1 removes all of them, which is
why it stays the priority rather than shortening the timeout, though a driver
that skips the exchange when `ATH10K_SNOC_FLAG_MODEM_STOPPED` is set would make
the wake far less painful in the meantime.


## The four-second threshold does not hold

An earlier reading of these results proposed that the modem tolerates about
four seconds of the suspended-device state and fails beyond it, which would
have explained why `#186` failed eight times out of eight while `#188` produced
clean cycles. Measuring the window directly refutes it.

Four consecutive `pm_test=devices` cycles on `#188`, with the suspended window
computed from the `dpm_suspend` phase boundaries:

```text
cycle 1 : dpm_suspend=0.00s  window=5.00s  watchdog=0
cycle 2 : dpm_suspend=0.06s  window=4.94s  watchdog=0
cycle 3 : dpm_suspend=0.06s  window=4.93s  watchdog=0
cycle 4 : dpm_suspend=0.07s  window=4.93s  watchdog=1
```

The window is essentially identical across all four and only one fails. On
`#186` a comparable window failed every time. So the window length does not
determine the outcome, and the difference between the two kernels is not
explained by it.

Two claims made from a single earlier sample are withdrawn with it: that
`dpm_suspend` takes 3.3 s on `#188`, and that the compiled-in instrumentation
is what slows it. It takes 0.06 s on these cycles; the single 3.30 s reading
was an outlier, most likely the first cycle after boot.

What survives is that the failure is intermittent on `#188` and was
deterministic on `#186`, which still points at timing, but through a mechanism
that neither the window length nor the tracing overhead accounts for.


## The failure rate, and no correlation with the modem's own transitions

Eight `pm_test=devices` cycles on `#188`, recording the modem's low-power entry
count from `qcom_stats` alongside the watchdog:

```text
cycle  island entries  watchdog
    1        1            1
    2       37            1
    3       37            1
    4       35            0
    5        0            1
    6       34            1
    7       38            0
    8        0            1
```

Six failures out of eight. The earlier four-cycle run that gave one failure was
too small a sample to build on, and the reading taken from it should not have
been offered as a model.

There is no correlation with the modem's own activity either. Cycles with 37
entries both fail and pass, and cycles with none at all still fail. Whatever
decides the outcome is not how many low-power transitions the modem attempts
during the window, which removes the coincidence-of-overlap explanation as
well.

So the position is: 8/8 failures on `#186`, 6/8 on `#188`, no dependence on the
suspended window length and none on the modem's transition count. The failure
is close to systematic on both kernels and the residual variation is not yet
attributable to anything measured.

## Current gate

Two defects remain in the way of a clean cycle, and the modem one is now
understood to be a race rather than a fixed condition.

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
