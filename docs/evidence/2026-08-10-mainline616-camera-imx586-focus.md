# Main-camera manual-focus validation

Date: 2026-08-10

## Result

The tested European HD1913 uses the Semco second-lens IMX586 module variant.
Its main-camera actuator is an ON Semiconductor LC898217XC at CCI address
`0x72`, not the AK7374 at `0x0c` selected by the other OxygenOS module
variants. Kernel package revision `r109` describes that hardware, binds
`lc898217xc 5-0072`, and exposes `focus_absolute` from 0 through 400 on
`/dev/v4l-subdev17`.

The actuator identity is grounded in the OxygenOS camera data. The vendor
partition contains separate `semco_imx586`, `semco_imx586_no_otp` and
`semco_2nd_lens_imx586` modules. The first two select AK7374 data; the latter
selects LC898217XC. The downstream OnePlus device tree independently confirms
that the main actuator uses CCI master 1, the 3.3 V camera VAF rail and GPIO25.
The AK7374 did not acknowledge at its documented address on this handset,
while the LC898217XC immediately completed its documented status and position
transactions.

## Hardware evidence

The direct-boot image reports
`#110-oneplus-hotdog-mainline616` and boot ID
`c9fcd09a-2a16-4dc6-a9f9-8c5943ee695e`. Both camera actuators bind:

```text
lc898217xc 4-0074: LC898217XC actuator ready
lc898217xc 5-0072: LC898217XC actuator ready
```

The main lens remained open while processed IMX586 frames were captured at
positions 0, 100, 200, 300 and 400. Every position produced ten complete
1280x960 PPM frames through libcamera's simple pipeline and software ISP. The
last frame at each position had a distinct SHA-256 digest. FFmpeg's blur
detector measured a strictly improving sequence as the lens moved toward the
ceiling focus plane:

| Focus position | Blur mean |
|---:|---:|
| 0 | 6.3138137 |
| 100 | 5.6640019 |
| 200 | 4.5675468 |
| 300 | 4.0899544 |
| 400 | 3.8513360 |

The visual result is equally clear: surface texture and edges are blurred at
position 0 and resolved at position 400. This validates main-camera manual
focus end to end, including the rail, CCI bus, actuator driver, optics, sensor,
CAMSS, software ISP and userspace capture path.

## Artifacts

| Artifact | SHA-256 |
|---|---|
| Kernel APK `6.16.0-r109` | `68ce7497433e8bb0c2306097c94612d757a5299cf904b691931f2773dfa02c85` |
| Corrected AVB `boot.img` | `6e44d40bfed5f93f991ac6fa0c1c114c8f739d48052fbc39b74b25ce39be5df4` |

The first assembled test image reused stale development rootfs UUIDs and
stopped in the postmarketOS initramfs shell. USB NCM and telnet remained
available, so the corrected image was transferred, hashed, written to
`boot_b`, read back in full and rebooted without physical recovery. The
hardware result above comes only from the corrected image using the published
Alpha rootfs UUIDs.

## Remaining work

Manual focus is complete. Libcamera `r4` subsequently added the autofocus
algorithm and simple-pipeline lens-control bridge described in the
[autofocus evidence](2026-08-10-mainline616-camera-autofocus.md). Production
colour, AWB calibration and additional IMX586 modes remain open.
