# Camera flash - 2026-08-12

## Starting point

`/sys/class/leds` held one entry, `mmc0::`, and nothing could drive the flash.
The cause was not a missing driver: `CONFIG_LEDS_QCOM_FLASH` was already built
and `pm8150l.dtsi` already describes the block:

```dts
pm8150l_flash: led-controller@d300 {
	compatible = "qcom,pm8150l-flash-led", "qcom,spmi-flash-led";
	reg = <0xd300>;
	status = "disabled";
};
```

Only the board side was missing, so the controller stayed disabled.

## Change

`0139` describes the two channels the handset wires to its dual flash,
following `sm8150-google-flame.dts`, which is the closest in-tree template: an
SM8150 handset with the same PMIC and the same two-channel arrangement.

Currents are the part's conservative per-channel figures rather than values
guessed from the stock tree. The driver clamps to the hardware maximum, and
under-driving an LED is harmless, so this is the safe direction to be wrong in.

`CONFIG_V4L2_FLASH_LED_CLASS` is enabled so libcamera can reach the LEDs
through a V4L2 subdevice rather than only through sysfs, and
`CONFIG_LEDS_QCOM_FLASH` is built in rather than modular so the LEDs exist
before userspace looks for them.

## Result

Both channels register:

```
/sys/class/leds/white:flash-0
/sys/class/leds/white:flash-1
```

Torch mode works on both. Writing `max_brightness` reads back 255 and clears
cleanly. Strobe works too:

| Attribute | Value |
| --- | --- |
| `max_flash_brightness` | 1000000 |
| `flash_strobe` after trigger | 1 |
| `flash_fault` | empty |

`flash_fault` staying empty is the interesting one: the driver reports no
open circuit, no short and no overtemperature, so the described currents are
within what the part accepts.

The one log line mentioning the flash is a udev timing message at 1.37 s about
`v4l2-flash-led-class.ko` not being present yet. It is the same benign
ordering artefact the NFC module produces, and the module loads normally
afterwards.

## Runtime follow-up - 2026-08-24

Both channels completed a brightness-32 torch test and a 100 mA, 100 ms strobe,
then returned to disabled state with no residual fault. The user confirmed that
the flash was visibly emitted.

The remaining gap is normal integration rather than electrical operation.
Plasma Camera presents no flash control. Plasma Mobile installs a flashlight
quick setting, but its backend matches only LED names ending exactly in
`:flash` or `:torch`; the two Hotdog channels enumerate as `white:flash-0` and
`white:flash-1`, so the backend reports no available flashlight.

The currents remain deliberately conservative and can be refined once the
stock figures are recovered. Camera synchronization and the Plasma quick
setting are the remaining support gaps.
