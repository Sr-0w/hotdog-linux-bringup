# Do not force a coredump on the ADSP

Date: 2026-08-19

Forcing a crash on the sensor DSP through
`/sys/kernel/debug/remoteproc/remoteproc0/crash` is safe and was done many times
during the sensor investigation: the SLPI stops, a devcoredump appears, and the
system carries on. Only the SLPI itself stays down until the next boot.

**The same thing on the ADSP wedges the machine.** `remoteproc2` produced no
coredump at all and its recovery never completed:

```
[3282.8] remoteproc remoteproc2: crash detected in adsp: type watchdog
[3282.8] remoteproc remoteproc2: handling crash #1 in adsp
[3282.8] remoteproc remoteproc2: recovering adsp        <- never finishes
```

Eight hundred seconds later it was still `crashed`, with kworkers stuck in
uninterruptible sleep on power management — `kworker/3:0+pm`, `kworker/7:0+pm`,
and the `sugov` threads. With the PM path held, three things become impossible:

- the ADSP cannot be restarted, `stop` then `start` hangs;
- the machine cannot reboot — `reboot`, `reboot -f` and even
  `echo b > /proc/sysrq-trigger` all return without doing anything;
- eventually even reading `/sys/class/remoteproc/remoteproc2/state` blocks.

Everything else keeps working: ssh, wifi, the modem and the SLPI stay up, and
the filesystem is untouched. It is a wedge, not a crash, and the only way out is
a physical power cycle.

Nothing was at risk when it happened — both slots held the known-good signed
image and no firmware or module had been modified — but it cost a manual reset,
so it is worth not repeating. If the ADSP's internal state is ever needed,
find another way to get it.
