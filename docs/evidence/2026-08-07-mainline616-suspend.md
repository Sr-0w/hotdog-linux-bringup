# Suspend bring-up - 2026-08-07

## Result

Incomplete. Process freezing works. Device suspend and resume runs but one
device still fails, so system suspend is not usable yet. Do not describe
suspend as working.

## What the hardware offers

| Item | Value |
| --- | --- |
| `/sys/power/state` | `freeze mem` |
| `/sys/power/mem_sleep` | `[s2idle]` only, no `deep` |
| Wakeup source | `rtc-pm8xxx` with `/sys/class/rtc/rtc0/wakealarm` |
| PowerDevil policy | automatic suspend disabled in all three profiles since device `3-r6` |

Only s2idle is available, so `mem` and `freeze` are the same state. Deep sleep
would need the RPMh sleep path and is not described.

## Instrumentation added

Revision `r37` enables `CONFIG_PM_DEBUG`, `CONFIG_PM_ADVANCED_DEBUG`,
`CONFIG_PM_SLEEP_DEBUG` and `CONFIG_DPM_WATCHDOG` with a 60 second timeout.

This matters for safety as much as for diagnosis. `/sys/power/pm_test` now
offers `core processors platform devices freezer`, and each level suspends only
up to that point then resumes automatically after five seconds. Suspend can
therefore be exercised without any risk of the device failing to wake. The
watchdog turns a device that hangs in a suspend callback into a diagnosable
event rather than an indefinite hang.

`/sys/power/suspend_stats/` also now reports `last_failed_dev`,
`last_failed_step` and `last_failed_errno`.

## Staged results

| `pm_test` level | Result |
| --- | --- |
| `freezer` | pass. User space froze in 0.002 s, remaining tasks in 0.001 s. |
| `devices` | devices suspend and resume, but the touchscreen fails to resume. |

```
s6sy761 0-0048: PM: dpm_run_callback(): s6sy761_resume returns -19
s6sy761 0-0048: PM: failed to resume async: error -19
last_failed_dev  0-0048
last_failed_step resume
```

Levels above `devices` were not attempted while a device still fails.

## Root cause of the touchscreen failure

`s6sy761_power_on()` re-enables the supplies, waits 140 ms, reads one event and
requires it to be `S6SY761_INFO_BOOT_COMPLETE`. It returns `-ENODEV` otherwise.
That check only passes if the controller actually restarted, and the driver
assumes dropping `vdd` and `avdd` guarantees it.

On this handset it does not. The regulator summary shows why:

```
ldo1    1 user   1800mV      0-0048-vdd
ldo10   2 users  3000mV      0-0048-avdd
                             18800000.wifi-vdd-3.3-ch1
```

`avdd` shares `ldo10` with the WCN3990 Wi-Fi chip. Whenever Wi-Fi is up, that
consumer keeps the rail enabled, so the touchscreen only loses its 1.8 V
digital supply. It never fully powers down, never restarts, never emits a
boot-complete event, and resume fails.

This is a driver assumption that does not hold on a shared rail, not a hotdog
integration mistake.

## Fix attempted

Revisions `r38` add:

- `0046`: optional `reset-gpios` support in the s6sy761 driver, pulsed inside
  `s6sy761_power_on()` so the controller restarts regardless of who holds the
  rails, and asserted in `s6sy761_power_off()`.
- `0047`: `reset-gpios = <&tlmm 54 GPIO_ACTIVE_LOW>` on the touchscreen node.

GPIO 54 is confirmed as the touchscreen reset by the stock device tree, whose
`Samsung_18821@48` node carries `reset-gpio = <... 0x36 0x00>` alongside
`irq-gpio = <... 0x7a ...>`, matching the interrupt already described here. The
existing pin state drives GPIO 54 high, so high is the released level.

The driver does acquire the line: requesting it from user space returns
`Resource busy`, and the touchscreen still probes and registers normally on
`r38`.

**The fix is not sufficient yet.** Resume still returns `-ENODEV`. The reset
line is owned and pulsed, so what remains is timing: the pulse holds reset for
only 1 to 2 ms and the driver then waits the original 140 ms before reading.
Vendor drivers for this family hold reset materially longer and allow more time
for the firmware to boot.

## Next steps

1. Widen the reset pulse and the post-reset wait, then repeat `pm_test=devices`.
2. Once `devices` passes, walk `platform`, `processors` and `core` in order.
3. Only then attempt a real s2idle with an armed `rtc0/wakealarm`.
4. Re-check the other suspend-sensitive subsystems afterwards: display
   blank/unblank, touch wake, Wi-Fi and Bluetooth power management.
