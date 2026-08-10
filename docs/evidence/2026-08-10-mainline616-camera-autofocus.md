# Main-camera autofocus and Plasma Camera validation

Date: 2026-08-10

## Result

Libcamera package revision `r4` added lens-control plumbing and a contrast
autofocus algorithm to the simple pipeline used by the SM8150 CAMSS port.
Revision `r7` makes autofocus wait for three consecutive stable AGC requests
before scanning and raises the normalized sharpness precision. The
Sony IMX586 now advertises `AfMode`, `AfTrigger` and normalized
`LensPosition` controls. Continuous autofocus is the default, so applications
that do not yet expose autofocus controls still receive a focused preview.

The implementation was informed by the February 2026
[libcamera-devel software-ISP lens-control proposal](https://lists.libcamera.org/pipermail/libcamera-devel/2026-February/057562.html)
and its [`millicam_af_6` development branch](https://gitlab.com/tui/libcamera/-/tree/millicam_af_6).
The packaged version additionally handles the CAMSS delayed sensor-control
path correctly: lens controls are applied independently of frame-start sensor
controls. It uses exposure-normalized green-channel horizontal edge energy,
performs a coarse scan followed by a bounded fine scan, waits one statistics
sample after every move, and publishes standard `AfState` metadata.

The stability test compares consecutive requested exposure/gain values rather
than delayed values returned in an older frame context. This matters when the
sensor reaches an exposure or gain limit: the active request is stable even if
the statistics pipeline still reports an older control value.

## Hardware validation

The test ran on direct-booted Linux `6.16.0-sm8150`, build marker
`#110-oneplus-hotdog-mainline616`, boot ID
`3be41344-d685-4a11-b9c2-dd19c1d22df6`. Libcamera enumerated both rear
cameras and exposed the following IMX586 controls:

```text
AfTrigger: Start, Cancel
AfMode: Manual, Auto, Continuous (default)
LensPosition: 0.0 through 1.0
```

A 180-frame 1280x960 processed run held 30 fps, scanned the physical
LC898217XC range from 0 through 400, refined the best coarse result and
reported:

```text
Autofocus completed at 400 (sharpness 34)
AfState = 2
LensPosition = 1.000000
focus_absolute: 400
```

A separate 220-frame 640x480 visual run selected an interior focus position,
which rules out a hard-coded endpoint result:

```text
Autofocus completed at 130 (sharpness 106)
focus_absolute: 130
```

Four retained frames from that run have distinct SHA-256 digests. FFmpeg
`blurdetect` improved from `4.8950138` on the initial frame to `4.0738420` on
the final frame. No CAMSS, SMMU or actuator error appeared during either run.

Plasma Camera then acquired the IMX586, configured a 3992x3000 ABGR8888
viewfinder, reached `setReadyForCapture true`, ran the same continuous
algorithm and completed at physical position 320 with sharpness 439. The app
currently labels the new AF controls as unknown because it has no dedicated
UI for them, but this does not prevent continuous autofocus from operating.

## Telephoto validation and AGC gating

The first telephoto run with revision `r6` exposed a boundary case rather than
starting autofocus. The dark scene saturated the sensor at exposure 3018 and
analogue gain 32, while the delayed frame context kept the AGC stability
counter at zero. Revision `r7` compares the new request with the previous
active request. On boot ID `5348118a-9d67-43d1-8eb1-82e4c9c442d8`, the next
run reached three stable samples and started autofocus immediately afterward.

With the camera facing a textured desk, the S5K3M5/LC898217XC pair produced a
monotonic coarse response and a bounded fine scan:

```text
position:       0    50   100   150   200   250   300   350   400
sharpness:   7259  7653  7575  7692  8029  7958  8100  8377  8766
Autofocus completed at 400 (sharpness 8878)
```

Two separate 640x480 manual captures then held the lens at positions 0 and
400. At 0 the desk seams are visibly defocused; at 400 the same lines are
separated and sharp. Their respective SHA-256 values are
`095dd1b5dd59b7da4916426888fa2462a5da461e7b55b547262347a5ae30cdd3`
and `b885a4f23e7c4f8fd37212beae149267816dabb34f4bb2319c83c55f1d377b3b`.
This validates automatic focus on both rear modules, while production tuning
still needs a center-weighted metric and scene-change thresholds.

## WirePlumber ownership fix

The first post-install test found WirePlumber holding `/dev/media0`, both
sensors and both actuators. The intended `monitor.libcamera = disabled` rule
was already packaged in `device-oneplus-hotdog-wireplumber`, but that
subpackage had no automatic installation condition. Device package `3-r17`
adds `install_if` for the device and WirePlumber. After installation and a
clean software reboot, WirePlumber remained active for audio while holding no
camera descriptor, and both cameras enumerated normally.

## Artifacts

| Artifact | SHA-256 |
|---|---|
| `libcamera-99990.7.2-r4.apk` | `c89e60d5d73b53cb59dd9dcc98185307d1e66f0c25b00bf235bd95c3282ae315` |
| `libcamera-ipa-99990.7.2-r4.apk` | `fd6778ef060e684a090b381cc7a3d024b0cd311df9ec5a9fbdd481ab766fa5ba` |
| `libcamera-tools-99990.7.2-r4.apk` | `69443c8adf056aedae3179d6dd49f37e77984d4f509fe755fcfde77229e40db7` |
| `libcamera-gstreamer-99990.7.2-r4.apk` | `284b9f7963aab7966a4563f4d3791a46d5a6e21f327d8f7e642584fb8329001e` |
| `device-oneplus-hotdog-3-r17.apk` | `cf8fa756336cdafd64780ce6f16853f3aaa04c6f580aa019a78c7707053db09c` |
| `device-oneplus-hotdog-wireplumber-3-r17.apk` | `d5e79206a1a04878133d34737f14f33ca4f0f4b3919e75c58c9744d48238663f` |
| `libcamera-99990.7.2-r7.apk` | `c99ce970941e67795e4097c913094f3111476e0cac18c5441146f0f59c423641` |
| `libcamera-ipa-99990.7.2-r7.apk` | `68d7b30b48cd55e0f23fab0b3863575556026029c53ff3879b9644bbbf92624b` |
| `libcamera-tools-99990.7.2-r7.apk` | `62088a2b11b9963a3bfa056f29d5715f790c86b7c5f28e14dc2f56e75e28ab7f` |
| `libcamera-gstreamer-99990.7.2-r7.apk` | `78b22ce749beadbe1a527cf43abbfd5e70e5fb12032e70b06b09fb77368e3a42` |
| `device-oneplus-hotdog-3-r18.apk` | `1feadb3a7c532f956c6191f289462994368f860d2f3036ff9332a8402755cd79` |

The libcamera source passed a native GCC 15 `-Werror` build and a strict
pmbootstrap aarch64 package build. The package has no upstream Meson tests.

## Remaining work

Calibrate autofocus thresholds against more scenes, replace the experimental normalized lens
position with calibrated lens-distance data, and complete production color
and AWB tuning. The IMX481 ultra-wide and IMX471 pop-up front camera remain to
be ported.
