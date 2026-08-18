# IPA wedges modem recovery from inside the SSR notifier chain

Date: 2026-08-18

## Summary

After a modem watchdog crash, the modem can become permanently unrecoverable:
every restart attempt fails with `can't lock rproc modem: -4`, and the only way
back is a reboot. The cause is an unbounded `wait_for_completion()` in
`gsi_trans_commit_wait()`, reached from IPA's subsystem-restart notifier while
the remote processor core holds the rproc lock.

This is not the suspend/resume defect under investigation. It is a separate bug
that the suspend testing kept triggering, and it is what turned recoverable
modem crashes into a phone that needed rebooting.

## Evidence

`echo w > /proc/sysrq-trigger` on a wedged device, kernel `6.16.0-sm8150`:

```
task:kworker/u32:...  state:D
  wait_for_common
  wait_for_completion
  gsi_trans_commit_wait      [ipa]
  ipa_filter_reset_table     [ipa]
  ipa_table_reset            [ipa]
  ipa_modem_notify           [ipa]
  notifier_call_chain
  srcu_notifier_call_chain
  ssr_notify_stop            [qcom_common]
  rproc_stop
  rproc_boot_recovery
  rproc_trigger_recovery
  rproc_crash_handler_work

task:modprobe         state:D
  wait_for_completion
  __synchronize_srcu
  synchronize_srcu
  srcu_notifier_chain_unregister
  qcom_unregister_ssr_notifier   [qcom_common]
  ath10k_snoc_free_resources     [ath10k_snoc]
  ath10k_snoc_remove             [ath10k_snoc]
  ...
  __arm64_sys_delete_module
```

The first task is the modem's own recovery worker. `rproc_trigger_recovery()`
takes the rproc lock, calls `rproc_stop()`, which runs the SSR notifier chain,
which reaches `ipa_modem_crashed()` and issues an IPA command channel
transaction. Nothing bounds the wait for that transaction, so the worker never
returns and never releases the lock. Every later boot attempt returns `-EINTR`:

```
remoteproc remoteproc1: can't lock rproc modem: -4
remoteproc remoteproc1: can't lock rproc modem: -4
remoteproc remoteproc1: Boot failed: -4
```

The second task shows how far the damage spreads. `rmmod ath10k_snoc`
unregisters its own SSR notifier, `synchronize_srcu()` waits for the chain to
drain, and the chain cannot drain while IPA is stuck inside it. An unrelated
driver is now unremovable.

## Fix

`net: ipa: bound the wait for a committed GSI transaction`.

Every caller of `gsi_trans_commit_wait()` is a command channel operation
(`ipa_mem.c`, `ipa_table.c`, `ipa_endpoint.c`), not a data path, and command
transactions complete in microseconds on a working device. The wait is now
`wait_for_completion_timeout()` with a 1 s bound and an error log, matching the
`GSI_CMD_TIMEOUT` convention already in `gsi.c`.

Returning early is safe, and the reference counting is what makes it so:

- `gsi_trans_commit_wait()` does `refcount_inc()` before `__gsi_trans_commit()`,
  so it holds a reference of its own.
- `gsi_trans_complete()`, on the GSI completion path, calls
  `complete(&trans->completion)` and then `gsi_trans_free()`, dropping the
  reference the machinery holds.

`gsi_trans_free()` only releases the transaction when the last reference goes,
so timing out and dropping ours cannot free a transaction the hardware may
still complete later.

## What the fix uncovered

With the wait bounded, recovery gets past the point where it used to hang, and
the failure underneath becomes visible for the first time:

```
remoteproc remoteproc1: recovering modem
ipa 1e40000.ipa: received modem crashed event
ipa 1e40000.ipa: channel 4 bad state 2 before start
ipa 1e40000.ipa: error -22 resuming channel 4
ipa 1e40000.ipa: channel 5 bad state 2 before start
ipa 1e40000.ipa: error -22 resuming channel 5
ipa 1e40000.ipa: channel 4: transaction did not complete in 1000ms   (x7)
ipa 1e40000.ipa: error -110 awaiting init driver response
```

State 2 is `GSI_CHANNEL_STATE_STARTED`. `ipa_modem_crashed()` takes a runtime
PM reference, which resumes IPA, and `ipa_endpoint_resume_one()` then calls
`gsi_channel_resume()` on channels it believes are stopped.
`gsi_channel_start_command()` accepts only `ALLOCATED` or `STOPPED`, finds
`STARTED`, and returns `-EINVAL`. Channel 4 is the command endpoint, so every
command transaction afterwards runs into the new timeout, and IPA's QMI
handshake with the restarted modem ends in `-110`. The modem never comes back
and the phone still needs a reboot, just for a different reason than before.

Two readings are possible and this file does not choose between them: either
the channels were never stopped on the way into suspend, in which case the
resume path is right to be surprised, or the modem crash left the GSI state
registers reporting something stale for channels the modem had a hand in. The
first would be answered by tracing `gsi_channel_suspend()` return values across
a cycle, the second by reading the channel state before and after a deliberate
modem crash with IPA runtime-resumed throughout. Neither has been done, so no
fix is proposed here yet; the last patch written on a plausible-sounding story
without that check made things worse.

## What this does not explain

Why the modem raises its watchdog around suspend in the first place. That
remains open; see `2026-08-17-suspend-resume-defects.md`. This bug only governs
what happens afterwards, and it is the reason several test runs ended with a
phone that had to be rebooted rather than one that recovered on its own.
