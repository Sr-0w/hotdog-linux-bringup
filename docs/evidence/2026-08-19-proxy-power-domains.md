# The proxy power domains are dropped from under a running modem

Date: 2026-08-19

## Summary

`qcom_pas_handover()` releases the proxy power domain votes as soon as the
remote processor signals it is up. That release only queues the domains for
power off; nothing acts on it until `genpd_suspend_noirq()` runs on the first
system suspend. By then the modem has been running for minutes, and it does
not survive losing `cx` and `mss` in that phase.

Fixed by `remoteproc: qcom_q6v5_pas: hold the proxy power domains until stop`.

## The signature this produces

The modem raises its watchdog on the **first** suspend of a boot and never
again on that boot. Six fresh boots, one real `s2idle` cycle each: six
crashes. Twenty-five consecutive cycles after the first one on a single boot:
zero. Once the domains are down there is nothing left to withdraw, which is
exactly what a deferred one-shot power off looks like.

That signature is also why this defect hid for so long behind statistics. A
campaign of twenty cycles reports one crash and a rate of five percent; the
rate is an artefact of campaign length, not a property of the defect.

## Measurement

One cycle per fresh boot, four boots per configuration, `pm_test=platform`
unless stated.

| configuration | boots | crashes |
| --- | ---: | ---: |
| unmodified, real `s2idle` | 6 | 6 |
| unmodified, `pm_test=platform` | 4 | 4 |
| `pm_test=devices` | 4 | **0** |
| `bam-dma-engine` and `geni_i2c` unbound | 4 | 4 |
| `smp2p-mpss` wakeup enabled | 4 | 4 |
| proxy votes never released | 4 | **0** |
| released synchronously, `pm_runtime_put_sync()` | 4 | 4 |
| **this patch** | 4 | **0** |

Then fifteen real `s2idle` cycles from a fresh boot, the first of them
previously fatal: **0 modem crashes and 0 Wi-Fi losses**.

## How it was found

`pm_test=devices` clean against `pm_test=platform` fatal put the trigger in
`dpm_suspend_late` or `dpm_suspend_noirq`. `bam-dma-engine` and `geni_i2c` are
the only bound drivers with callbacks in those phases, and removing both
changed nothing, so it was not a driver callback but the PM core's own work.
Arming the modem's SMP2P interrupt as a wake source, which stops
`suspend_device_irqs()` masking it, changed nothing either. That left
`genpd_suspend_noirq()`, and keeping the proxy votes confirmed it.

Note that `pm_runtime_put_sync()` does **not** fix it: making the release
immediate still crashes 4/4. What matters is not when the vote is dropped but
that `cx` and `mss` are up while the suspend runs. Releasing at stop gives
that for exactly as long as something depends on them.

## What is not established

The power cost of holding `cx` and `mss` for the life of the remote has not
been measured. Downstream drops its proxy on a ten second timeout
(`qcom,proxy-timeout-ms = <0x2710>`) and its modem survives, which suggests a
cheaper arrangement exists that this patch does not find.
