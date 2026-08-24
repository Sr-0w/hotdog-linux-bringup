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

The guided helper at `/home/user/test-hotdog-quick-wins` monitors events live
and finishes only after values 0, 1 and 2 have all been observed.

## The lower contact was intermittently open

The live monitor repeatedly saw values 0 and 1, but never 2. Two guided raw
GPIO passes made the failure specific:

```text
top     gpio27=1 gpio125=0 gpio134=1
middle  gpio27=1 gpio125=1 gpio134=0
bottom  gpio27=1 gpio125=1 gpio134=1
```

GPIO125 and GPIO134 accumulated interrupts; GPIO27 remained at zero
interrupts. With the slider held at the bottom and the input driver briefly
unbound, GPIO27 still read high with internal pull-up, pull-down and bias
disabled. Its TLMM control register is `0x00000000` and IO register
`0x00000001`: GPIO mode, input, no pull, physical high.

That observation was real but transient. It did not establish a mainline
electrical defect. Immediately before the later downstream control, with the
slider still physically at the bottom, GPIO27 had started reading low under
mainline.

Treating all contacts open as Ring was tested and rejected. It produces a false
Ring event in the break-before-make gap between top and middle, and it does not
match OxygenOS. The generic fallback driver and its DT change were reverted in
kernel commits `cf895477e6b8` and `cec17152dbd5`; the phone was restored to the
honest `gpio-keys` boot with SHA256
`628402b510a971901fbe8c2ed6dfc2c50632d97f5313ab978c82a7c53bf2ca68`.

## OxygenOS reverse engineering

This is not a wrong-GPIO guess. Four independent vendor sources agree:

1. The exact OxygenOS 10.0.13 `dtbo.img` has 38 entries. Entry 5, the overlay
   selected on this phone, defines `gpio_key1=<TLMM 27>`,
   `gpio_key2=<TLMM 134>`, `gpio_key3=<TLMM 125>` and configures all three as
   GPIO, 2 mA, bias disabled.
2. The archived merged live DT contains the same values.
3. The OnePlus Q and S/12.1 source branches keep the same mapping for project
   19801.
4. Kallsyms reconstructed from the exact OxygenOS 10.0.13 boot kernel exposes
   `extcon_dev_work`. Its disassembly reads key1/key2/key3 raw and explicitly
   accepts only `0,1,1` as the lower position; `1,1,1` returns without a
   report.

The downstream and mainline pinctrl group tables also agree that GPIO27 is on
the East tile at TLMM register `0x351b000`. The downstream-only eGPIO metadata
is not relevant here: bit 11 (`egpio_present`) is clear in the live control
register. There is therefore no evidence for another GPIO or a tile-address
bug.

A host-only kexec attempt using the boot-proven downstream Image and a DT
rebuilt from the archived OxygenOS live tree did not reach userspace. It is not
used as slider evidence.

## Downstream control and immediate mainline comparison

The decisive control used the exact previously booted R6 pair rather than a
reconstructed DT:

- boot image SHA256
  `28c08d1668955a791f24d0d392658b06d1e452921f04be60c44278d27014966b`;
- stock `dtbo_b` SHA256
  `95a111deb5302d0fc677c3d58f880a049461ffcaba856c75471d2789040ae672`;
- Linux `4.14.357-openela-perf #6-postmarketOS`;
- ABL-selected `androidboot.dtb_idx=12` and `androidboot.dtbo_idx=5`.

With the slider left in the bottom position, the OnePlus driver reported:

```text
key[0]=0,key[1]=1,key[2]=1
report down key successful!
```

`/proc/tristatekey/tri_state` returned `3` for 20 consecutive reads, GPIO27's
TLMM IO register was low, and the registered IRQ was named `tristate_key1`.
This proves both that GPIO27 is the lower contact and that the contact can
close electrically on this handset.

The exact mainline boot and no-op DTBO were then restored without moving the
slider. Linux 6.16 read GPIO27 low in 50 consecutive samples. Therefore the
downstream boot did not supply a persistent rail, pinmux, pull or other
electrical enable missing from mainline. Both kernels see the same closed
contact when the mechanism reaches it.

The earlier all-high bottom samples are best explained by intermittent
mechanical travel or contact at the lower detent. Mapping all contacts open to
Ring remains rejected because it creates a false Ring report during normal
break-before-make travel. The honest `gpio-keys` implementation is retained.

The alert slider is now **Working**: Silent and Vibrate were physically
validated in the guided run, and Ring is validated by the stock downstream
driver followed immediately by 50 stable mainline GPIO27-low reads in the same
physical position.
