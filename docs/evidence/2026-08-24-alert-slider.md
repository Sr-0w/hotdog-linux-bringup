# Three-position alert slider - 2026-08-24

## Source of truth

The saved OxygenOS device tree and the published OnePlus SM8150 kernel agree
on the direct mechanical slider used by project 19801:

| Contact | GPIO | Active stock state |
| --- | ---: | --- |
| key 1 | TLMM 27 | low means Ring |
| key 2 | TLMM 134 | low means Vibrate |
| key 3 | TLMM 125 | low means Silent |

The stock driver's truth table is one active-low contact at a time:

```text
GPIO27 GPIO134 GPIO125
   1      1       0     Silent
   1      0       1     Vibrate
   0      1       1     Ring
```

This is not inferred from a related OnePlus model. The same GPIOs are present
in the archived live DT under `/soc/tri_state_key`, and a downstream boot on
this handset logged `key[0]=1,key[1]=0,key[2]=1` and reported the middle
position.

## Mainline representation

No vendor driver is needed. Mainline `gpio-keys` supports an absolute axis and
a distinct value per active GPIO. The Hotdog DT now follows the upstream
OnePlus alert-slider convention:

- input name `Alert slider`;
- `EV_ABS`, `ABS_SND_PROFILE`;
- values `SND_PROFILE_SILENT=0`, `SND_PROFILE_VIBRATE=1`,
  `SND_PROFILE_RING=2`;
- pinctrl function GPIO, 2 mA and no internal bias, matching OxygenOS.

Linux 6.16 predates the sound-profile input constants, so commit
`e629d89c4665` backports the UAPI values. Commit `0a3a3424fb19` adds the generic
DT description. The latter also names the first PM8150L flash channel
`white:torch`, allowing Plasma Mobile's existing flashlight backend to find
it while the QCOM flash driver retains torch, strobe and V4L2 capabilities.

The DTB build and direct `gpio-keys.yaml` validation pass. The candidate boot
image is 100663296 bytes with SHA256
`628402b510a971901fbe8c2ed6dfc2c50632d97f5313ab978c82a7c53bf2ca68`.
The guarded `boot_b` readback matched before reboot.

## Runtime

The new boot returned in 34 seconds with taint 512. It exposes:

```text
N: Name="Alert slider"
P: Phys=gpio-keys/input0
S: Sysfs=/devices/platform/alert-slider/input/input3
H: Handlers=event3
```

Udev reports `ID_PATH=platform-alert-slider` and
`FEEDBACKD_TYPE=alert-slider`. The packaged XDG autostart runs
`/usr/libexec/fbd-alert-slider`, which holds `/dev/input/event3` open. During
the first guided attempt, GPIO134 became low, `ABS_SND_PROFILE` read 1 and the
feedbackd D-Bus `Profile` property read `quiet`. IRQ counters also increased
on the Silent and Vibrate contacts. Thus the middle position already works
from physical contact through feedbackd.

The guided helper at `/home/user/test-hotdog-quick-wins` now monitors events
live and finishes only after values 0, 1 and 2 have all been observed. Final
three-position validation remains pending that log.
