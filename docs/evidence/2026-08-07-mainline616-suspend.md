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

## Fix attempted, and what it ruled out

Revisions `r38` through `r41` add:

- `0046`: optional `reset-gpios` support in the s6sy761 driver. The reset is
  driven around the supply change, the boot-complete event is polled for with
  a bounded timeout instead of sampled once at a fixed delay, and the whole
  restart is retried three times.
- `0047`: `reset-gpios = <&tlmm 54 GPIO_ACTIVE_LOW>` on the touchscreen node.

GPIO 54 is confirmed as the touchscreen reset by the stock device tree, whose
`Samsung_18821@48` node carries `reset-gpio = <... 0x36 0x00>` alongside
`irq-gpio = <... 0x7a ...>`, matching the interrupt already described here. The
existing pin state drives GPIO 54 high, so high is the released level.

**Resume still fails with -ENODEV.** The work is kept because the driver
changes are correct on their own, and because the instrumentation eliminated
most of the plausible causes. What is now established:

| Checked | Result |
| --- | --- |
| Does the driver own the reset line? | Yes. Requesting it from user space returns `Resource busy`. |
| Does the line actually move? | Yes. It reads back as asserted then released around the pulse. |
| Is the reset long enough? | It is held 10 ms, and the restart is retried three times over roughly 1.7 s. |
| Is `vdd` back? | Yes. `ldo1` reads enabled at 1800 mV with the touchscreen as its consumer, during and after the failed resume. |
| Is the I2C bus down? | No. `geni_i2c_xfer()` takes a runtime PM reference and would return an error; reads succeed and return data. |
| Is the controller broken afterwards? | No. The input device survives, and an unbind/rebind recovers it immediately. |

The remaining symptom is narrow and reproducible: during resume the controller
answers every event read with all zeroes for the full retry window, while the
identical `s6sy761_power_on()` path invoked seconds later through unbind and
rebind gets a boot-complete event on its very first read, with no retry.

So the controller, its supply, its reset line and its bus are all fine. Only
the resume context is not, and nothing checked so far explains it.

## Next steps

1. Log `S6SY761_BOOT_STATUS` during the failed window to separate "held in
   bootloader" from "not answering at all".
2. Compare against a real s2idle with an armed `rtc0/wakealarm`, in case the
   `pm_test=devices` path itself is what the controller reacts to.
3. Consider deferring the touchscreen restart to a `.complete()` callback or a
   work item, so it runs once the whole device tree is back rather than inside
   the resume phase.
4. Only once `devices` passes, walk `platform`, `processors` and `core`, then
   attempt a real suspend.
5. Re-check display blank/unblank, touch wake, and radio power management
   afterwards.
