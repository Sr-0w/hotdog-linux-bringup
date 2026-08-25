# ath10k never declares that it can wake the system, so Wi-Fi dies on suspend

> Fixed in the current kernel checkpoint; Wi-Fi survives the validated suspend
> cycles. This file remains the root-cause evidence.

Date: 2026-08-19

## Summary

`ath10k_snoc` implements a suspend path for WoWLAN and gates it on a capability
it never declares, so the path is dead code. mac80211 falls back to tearing the
connection down on every system suspend, that teardown times out against the
firmware, and the interface is then unrecoverable without a reboot.

Fixed by `wifi: ath10k: declare the snoc device as wakeup capable`, with
`wifi: ath10k: recover when the firmware still thinks WLAN is on` as a
backstop for the state the old behaviour leaves behind.

## The defect

```c
static int ath10k_snoc_hif_suspend(struct ath10k *ar)
{
	if (!device_may_wakeup(ar->dev))
		return -EPERM;
```

Nothing in the driver calls `device_init_wakeup()`, so `device_may_wakeup()` is
always false and both `ath10k_snoc_hif_suspend()` and its resume counterpart
always return `-EPERM`. `/sys/.../18800000.wifi/power/wakeup` reads `disabled`
on a stock boot.

`ath10k_wow_op_suspend()` therefore cannot complete, and mac80211 takes the
teardown path instead:

```
wlan0: deauthenticating from f8:d2:ac:4f:82:b8 by local choice
ath10k_snoc: failed to install key for vdev 0 peer f8:d2:ac:4f:82:b8: -110
wlan0: failed to remove key (0, ...) from hardware (-110)
```

The WMI command times out after three seconds. The firmware is left believing
WLAN is enabled, and afterwards refuses both the enable and the disable that
would clear it, with `QMI_ERR_INCOMPATIBLE_STATE_V01`:

```
ath10k_snoc: config request rejected: 90
ath10k_snoc: wlan left enabled in firmware, turning it off
ath10k_snoc: more request rejected: 90
```

The capability is not hypothetical: the interrupt those handlers arm as a wake
source is one of the copy engine interrupts the driver already requests, and
the firmware advertises `wowlan` among its features.

## Measurement

Real `s2idle` cycles, counting whether `wlan0` still holds its address
afterwards:

| configuration | Wi-Fi lost |
| --- | --- |
| stock | 13/15 |
| `device_init_wakeup()` plus WoWLAN triggers configured | **0/12** |

With the fix in place and `iw phy0 wowlan enable magic-packet disconnect`, no
`deauthenticating` and no `rejected: 90` appears anywhere in the run. The
destructive teardown simply stops happening.

## The tradeoff this exposes

`ath10k_snoc_hif_suspend()` arms `ce_irqs[ATH10K_SNOC_WAKE_IRQ]`, copy engine 2,
as a system wake source. On a busy network that fires on ordinary received
traffic, so the phone wakes almost immediately: cycles that should last 22 s
return in 1.6 s, with `/sys/power/pm_wakeup_irq` naming `WLAN_CE_2`. Some
cycles do sleep the full 22 s, so the firmware is filtering at least part of
the time, but not reliably.

Enabling WoWLAN is therefore a policy decision rather than a free win, and it
is the same decision the downstream stack makes: OxygenOS keeps the link up
across suspend instead of tearing it down. What the kernel patch changes is
that the choice exists at all.

## Status

Both patches are local and queued in
[the upstream submission queue](../upstream-submissions.md). The wake-capability
patch is the fix; the `INCOMPATIBLE_STATE` recovery is worth keeping regardless,
since a driver holding the command that clears a permanent failure should use
it.
