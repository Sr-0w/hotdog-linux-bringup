# Disabled R6 UFS live probe

> [!CAUTION]
> Do not load an older build of this module on hardware. In particular, never
> load a file with SHA256
> `2100b2c93190fdbfbdb61b8ef2d77b5dfc5b6378c13eacc898591fb1ce00396f`.

This directory preserves a failed diagnostic experiment. The original module
called the downstream 4.14 `ufshcd_hold()` API before reading a fixed set of
UFS host, PHY, and local UniPro values. On the tested OnePlus 7T Pro, the
controller was clock-gated and its link was in hibern8. The hold operation
attempted to wake the link, timed out, entered vendor UFS recovery, and left
`insmod` blocked in uninterruptible sleep.

The source now fails closed with `-EPERM` before locating or touching any
device. Git history retains the original experiment for review, while
[the incident evidence](../../docs/evidence/2026-08-01-r6-ufs-live-probe.md)
records the exact binary, kernel trace, and outcome.

Use these sources of reference data instead:

- the normal R6 boot log for negotiated gear, lane count, mode, rate, device
  identity, and LUN enumeration;
- the driver's timeout dump captured by the failed experiment for the host
  register and clock snapshot at the failure boundary;
- boot-time instrumentation inside a disposable diagnostic R6 kernel if a
  future comparison requires values unavailable from existing logs.

Do not use raw MMIO, `ufshcd_hold()`, DME commands, runtime-PM changes, or
debugfs register reads from a healthy R6 rescue session. Those operations can
change the controller state and invalidate the session being measured.
