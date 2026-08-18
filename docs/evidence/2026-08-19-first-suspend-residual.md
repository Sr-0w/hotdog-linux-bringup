# The residual modem crash happens on the first suspend after boot

Date: 2026-08-19

## What it looks like

After the `sdhc_2` power domain fix, the modem watchdog no longer fires at
random. It fires on the **first** `s2idle` cycle after boot and then not again.

| campaign | cycles | crashes | crash at cycle |
| --- | ---: | ---: | --- |
| A | 20 | 1 | 2 |
| B | 15 | 1 | 1 |
| C | 25 | 1 | 1 |
| D | 3 | 1 | 1 |
| E, after the fix attempt below | 3 | 1 | 1 |

Twenty-five consecutive clean cycles follow the single crash in campaign C. The
rate over a whole campaign, roughly 4 to 6 percent, is entirely explained by
that one cycle.

## What it is not

- **Not a settling problem.** Waiting two minutes after boot before the first
  suspend does not prevent it. Campaign E crashed on cycle 1 with a 2 minute
  idle beforehand.
- **Not a device callback.** Comparing the traces of the crashing cycle 1 and
  the clean cycle 2 of the same boot: the suspended device lists are identical,
  1011 entries against 1012, the extra one being the `devcoredump` the crash
  itself creates. Callback durations match to the millisecond, the only
  difference being `ieee80211 phy0` at 30.3 s on cycle 1, which is `ath10k`
  burning its QMI timeout after the modem is already dead.
- **Not AP-to-modem traffic.** Zero GLINK, QRTR or SMP2P events in the two
  seconds before the crashing suspend.
- **Not the `mss` power domain vote.** An earlier reading of these traces
  claimed cycle 1 wrote `mss.lvl` and cycle 2 did not, which suggested the
  proxy vote was being dropped from underneath a running modem. Making
  `adsp_pds_disable()` release synchronously with `pm_runtime_put_sync()`
  changed the timing but not the outcome, and with it applied cycle 2 writes
  `mss.lvl` too and stays clean. The extra `mss.lvl 0x9`, `cx.lvl 0x7` and
  `mx.lvl 0x7` seen only on cycle 1 are the maximum corners that
  `adsp_pds_enable()` places when restarting the modem, so they are the crash's
  consequence. The patch was reverted rather than kept on a story that did not
  survive its own test.

## A level split that did not hold

One run suggested the trigger sat between `pm_test=devices` and
`pm_test=platform`: on a fresh boot `devices` came out clean and a `platform`
cycle straight after it killed the modem, and in a separate run a first
`platform` cycle killed it while the two real `s2idle` cycles that followed
were clean. A third run then gave a clean `platform` cycle on a fresh boot,
with the same `mss.lvl 0x0` and `mss.lvl 0x1` writes present as in the runs
that crashed.

So the split is not real and neither is the determinism it seemed to offer.
Recorded here because it was asserted on two observations before the third
contradicted it, which is the same mistake this file warns about elsewhere.
The `mss.lvl` writes appear in crashing and clean first cycles alike and do
not discriminate.

## Where that leaves it

The crash is confined to `machine_suspend`: `pm_test=devices` is 0/15 and
`pm_test=platform` is 0/12, both clean. Disabling the deepest cpuidle state
changes nothing, 0/8 against 0/8. The modem's own watchdog interrupt, armed as
a wake source by the local `qcom_q6v5` patch, aborts the `s2idle` loop in about
1 ms on a crashing cycle, so a 1.2 ms `machine_suspend` in a trace is a symptom
rather than a cause.

Something about a first suspend differs from every later one, and nothing
visible in the PM callback trace, the RPMh votes, the interconnect votes or the
inter-processor traffic captures it. The next thing worth trying is the modem
side: its own logs across the first cycle, rather than the AP's view of it.
