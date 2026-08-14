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

Device package `3-r20` applies a stricter temporary policy because display
blanking itself can leave the handset black and unreachable. For the `AC`,
`Battery`, and `LowBattery` profiles it disables automatic suspend, dimming and
display blanking. A KDE session autostart writes the same values into the live
user profile, disables automatic locking and locking on resume, reloads
PowerDevil through D-Bus, and requests an immediate wake.

The Plasma Mobile application subpackage also installs and enables the OpenRC
service `hotdog-no-sleep`. It runs `elogind-inhibit` as root and blocks both
`idle` and `sleep`; unlike the generic postmarketOS `sleep-inhibitor`, this
inhibitor is visible explicitly in elogind:

```text
WHO             WHAT        MODE
hotdog-no-sleep sleep:idle  block
```

The live handset accepted `device-oneplus-hotdog-plasma-mobile-apps-3-r20`
without taking ownership of Plasma's `/etc/xdg/kscreenlockerrc`. The session
policy is instead installed under `/usr/libexec` and runs through an XDG
autostart entry. This avoids an APK file-ownership conflict while retaining
per-user KDE configuration. A subsequent direct reboot started
`hotdog-no-sleep` automatically and restored USB networking and SSH with a new
boot ID.

The built package hashes are:

```text
device-oneplus-hotdog-3-r20.apk
74d0fd1d0f7cfc6225203746c21439989ca4ebadbcc399d05214e73f1fff67ef

device-oneplus-hotdog-plasma-mobile-apps-3-r20.apk
816e060b7ce106ecbe90dac5e2b69fccbba50f3e901e9f9d659ca6b4635cb24d
```

This was the initial temporary bring-up reliability policy. Explicit suspend
testing still requires stopping `hotdog-no-sleep` first. The display-only path
was subsequently validated and enabled as described below; automatic system
suspend remains blocked.

## Display-only idle retest

On 2026-08-14, KWin DPMS was tested independently from system suspend on the
full Plasma Mobile image running `6.16.0-sm8150 #177-smb5-v3-ba989060`.
`kscreen-doctor --dpms off` reported `DSI-1: off` for the complete 50-second
observation. All ten five-second samples retained the same USB device, ping,
SSH access, boot ID, online charger and readable power-supply properties. The
screen was then restored with `kscreen-doctor --dpms on` without a reboot.

The raw host monitor is retained outside Git under:

```text
logs/display-dpms-usb-ssh-20260814-223230/monitor.log
```

Device package `3-r24` therefore enables display-only idle blanking after 120
seconds for the `AC`, `Battery` and `LowBattery` profiles. It continues to
disable automatic suspend and screen locking. The `hotdog-no-sleep` inhibitor
now blocks only `sleep`, rather than `idle:sleep`, so PowerDevil can blank the
OLED while USB networking and SSH remain available. The policy and updated
inhibitor were also installed on the running full image; its display was left
in DPMS off with the original boot ID
`ab9a6a1a-b612-43fc-93e9-b0c29e425776`.

The complete Plasma Mobile policy subpackage was rebuilt successfully:

```text
device-oneplus-hotdog-plasma-mobile-apps-3-r24.apk
sha256 db8ace51bb358584046c69d34aa4588413d7e285be65072804d7e44419059d96
```

## Remaining work

- fix DWC3 PHY suspend preparation and USB gadget resume;
- fix S6SY761 resume returning `-ENODEV`;
- verify UFS, display, touch, Wi-Fi, and Bluetooth across repeated explicit
  suspend/resume cycles;
- determine which wake sources can resume the SoC without the physical power
  key;
- remove the system-suspend inhibitor once unattended resume is reliable.
