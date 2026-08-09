# Mainline telephoto manual-focus validation

Date: 2026-08-09

## Result

The OnePlus 7T Pro test handset uses the Semco telephoto module variant with an
ON Semiconductor LC898217XC voice-coil actuator at CCI address `0x74`.
Revision `r87` direct-boots Linux 6.16 as
`#88-oneplus-hotdog-mainline616`, binds `lc898217xc 4-0074`, and exposes a V4L2
lens subdevice with this calibrated control:

```text
focus_absolute: min=0 max=400 step=1 default=50
```

The driver uses the vendor-described status register `0xb3` and big-endian
two-byte DAC writes at register `0x84`. Power is supplied through the existing
`cam1_vaf` and 1.8 V I/O regulators. It performs no undocumented register
writes.

## Hardware evidence

Five captures used identical S5K3M5 settings: 4208x3120 packed GRBG RAW10,
exposure 2000 lines and analogue gain 4. The lens subdevice remained open
during each capture so runtime power management retained the requested
position. Positions 0, 100, 200, 300 and 400 all produced three complete,
distinct 16,423,680-byte frames without CAMNOC, SMMU or I2C errors.

The optical result is unambiguous: position 0 blurs the ceiling joints and
surface grain, while position 400 resolves both. A second position-400 capture
after a cold `r87` boot reproduces the focused image. This validates physical
lens movement and manual focus end to end.

The strict-build kernel APK SHA256 is
`03b62ce65d1541793f2dd3f91465f915654953d8e4c2896ff63a9fbbdd467b3c`.
The fixed-size AVB boot image SHA256 is
`3bd3248bd91076337ab8602144b039e3089090a2ba1133d857d45d73d4eae3d0`.
The flashed `boot_b` readback matched that hash exactly.

## Remaining userspace work

This is manual V4L2 focus, not continuous autofocus. Libcamera still needs a
camera profile, lens-search algorithm, automatic exposure/gain/white-balance,
color tuning and camera-application integration. The main, ultra-wide and
front sensors remain separate kernel bring-up tasks.
