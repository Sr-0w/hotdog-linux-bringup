# Plasma idle-suspend policy

## Result

The fixed-90-Hz `r16` system reached Plasma Mobile's default 15-minute idle
deadline and attempted `s2idle`. Ramoops records the exact sequence:

```text
[  924.790458] PM: suspend entry (s2idle)
[  924.911307] dwc3-qcom-legacy a6f8800.usb: port-1 HS-PHY not in L2
[  925.063025] s6sy761 0-0048: PM: dpm_run_callback(): s6sy761_resume [s6sy761] returns -19
[  925.331131] PM: suspend exit
```

The handset then remained black and absent from USB. A short physical
power-button press restored the same Linux boot, USB networking, and SSH; boot
ID `58f50ee9-acff-4855-840d-abadf0cbd1b9` did not change. This was not a reboot,
but it was also not a clean suspend/resume cycle: DWC3 failed to enter the
required PHY state and the touchscreen resume callback failed.

After the wake, the system later entered Qualcomm `900e` without a Linux panic,
oops, or call trace. The bounded ramoops capture contains one post-wake runtime
record with UFS active, the USB gadget configured, and Bluetooth idle. I
subsequently identified software-install attempts as the repeated trigger for
these transitions. No evidence currently links that crashdump to the earlier
system-suspend attempt; storage-load stability is tracked separately.

## Policy

Device package `3-r5` installs Plasma 6 PowerDevil defaults with
`AutoSuspendAction=0` for the `AC`, `Battery`, and `LowBattery` profiles. Screen
blanking, locking, the power-button screen action, and explicit user-requested
suspend are unchanged. The same values were applied to the existing live user
profile and reloaded through PowerDevil's D-Bus interface without rebooting.

This is a temporary reliability policy. It prevents the default mobile timeout
from interrupting unattended development while preserving controlled
suspend/resume testing.

## Remaining work

- fix DWC3 PHY suspend preparation and USB gadget resume;
- fix S6SY761 resume returning `-ENODEV`;
- verify UFS, display, touch, Wi-Fi, and Bluetooth across repeated explicit
  suspend/resume cycles;
- determine which wake sources can resume the SoC without the physical power
  key;
- remove the conservative default once unattended resume is reliable.
