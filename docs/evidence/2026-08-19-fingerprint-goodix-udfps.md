# Fingerprint: what the hardware is and why mainline cannot authenticate with it

Date: 2026-08-19

## The sensor

`G_OPTICAL_18865_G3`, a Goodix in-display optical sensor. The name comes from
the stock DTBO entry 5, the overlay the OnePlus bootloader applies on top of
our DTB:

```dts
oplus_fp_common {
        compatible = "oplus,fp_common";
        oplus,fp_gpio_num = <1>;
        oplus,fp_gpio_0 = <&tlmm 90 0>;

        goodix_optical {
                oplus,fp-id = <1>;
                vendor-chip = <0x0b>;
                chip-name = "G_OPTICAL_18865_G3";
        };
};

goodix_fp {
        compatible = "goodix,goodix_fp";
        interrupts = <118 0>;
        goodix,gpio_irq = <&tlmm 118 1>;
        goodix,gpio_reset = <&tlmm 131 0>;
        goodix,goodix_pwr = <&tlmm 101 0>;
        power-mode = <2>;               /* GPIO-switched supply */
        power-num = <1>;
};
```

| line | role |
| --- | --- |
| tlmm 90 | vendor identification, read to select the Goodix variant |
| tlmm 101 | supply enable |
| tlmm 118 | interrupt, active low |
| tlmm 131 | reset |

Those nodes are present at runtime on this port, since the bootloader applies
the overlay, but no mainline driver claims them: all four pins read
`MUX UNCLAIMED` in `pinctrl/pinmux-pins` and `unnamed input` with no consumer
in `gpioinfo`.

## Why authentication cannot work on mainline

**There is no SPI node.** The downstream `goodix_fp` binding describes power,
reset and interrupt and nothing else. The sensor's data bus does not belong to
Linux at all.

`vendor/lib64/libgf_ud_hal.so`, the real Goodix HAL behind the thin
`goodix.fod.msmnile.so` shim, settles it. It links against `libQSEEComAPI.so`
and calls `QSEECom_start_app`, `QSEECom_send_modified_cmd` and
`QSEECom_shutdown_app`. Capture, image processing, template storage and
matching all happen inside a Qualcomm TrustZone applet. The only kernel
interface it uses for the sensor itself is `/dev/goodix_fp`, the downstream
character device that does power, reset and interrupt delivery.

So the fingerprint image never reaches Linux, on stock or anywhere else. Three
things would each have to be solved before `fprintd` could see anything:

1. a QSEECom equivalent in mainline able to load and talk to a signed
   Qualcomm trustlet, which mainline does not have;
2. the trustlet's listener services, which downstream provides from the kernel
   side for RPMB and filesystem access;
3. failing all that, a full reimplementation of the Goodix protocol and
   matcher in userspace. `libfprint` has no driver for this sensor family and
   no image to work from, since the bus is not ours.

## What the HAL also needs, which is useful independently

`libgf_ud_hal.so` drives the display for illumination:

```
/sys/.../card0-DSI-1/hbm          high brightness mode, lights the finger
/sys/.../card0-DSI-1/aod
/sys/.../card0-DSI-1/notify_dim
/sys/.../panel0-backlight/brightness
/proc/touchpanel/touch_hold       touch coordination under the sensor area
```

An under-display optical sensor only raises its interrupt when a finger is
present **and lit**, which is why a passive test proves nothing about whether
the sensor is alive.

## What was tested

The four lines are free, so the supply and reset were driven directly with
`libgpiod` and the interrupt watched with `gpiomon`: supply high, reset
released, twelve seconds. **Zero edges.** That is the expected result without
illumination and without the trustlet driving the sensor, and it neither
confirms nor rules out a working sensor.

## Where this leaves the row

`Fingerprint | Not yet supported` stays accurate. What is now known is that
this is not a missing-driver problem that effort would close: the blocking
piece is a signed TrustZone applet that owns the sensor. Writing DT nodes and
a mainline GPIO driver is achievable and would be honest groundwork, but it
would not authenticate anything, and it should not be presented as progress
toward a working fingerprint.
