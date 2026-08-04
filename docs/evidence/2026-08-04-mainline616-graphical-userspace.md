# Mainline 6.16 graphical userspace validation

Date: 2026-08-04

Device: OnePlus 7T Pro HD1913 (`hotdog`)

Result: the package-built `r8` kernel drives the physical panel through native
DRM/KMS, renders with the Adreno 640, maps the S6SY761 touchscreen correctly,
and runs a usable postmarketOS Plasma Mobile session after a direct boot from
the OnePlus bootloader.

## Tested system

The test reused the fully read-back `r8` AVB image with SHA256
`32d5e2a4cea4d31c4200dbf6da82abfc7e2a25b717f3a3c7a017a688c3cf6376`.
The running system reported:

```text
Linux hotdog 6.16.0-sm8150 #9-oneplus-hotdog-mainline616
boot ID: 7c7e99b7-8714-4836-9ec2-e23b77732a08
root: /dev/loop0p2 ext4 rw
DRM connector: DSI-1 connected, 1440x3120 at 60.0 Hz
render node: /dev/dri/renderD128
```

USB NCM and SSH remained available throughout the graphical tests. No kexec or
downstream kernel executed during this boot.

## Accelerated KMS rendering

`kmscube` selected EGL 1.5, OpenGL ES 3.2, Mesa 26.1.6, the Freedreno driver,
and renderer `FD640`. A 600-frame physical-display run completed at 59.45 FPS.
A second 30-second run held approximately 59.9 to 60.0 FPS. The rotating cube
filled the panel with correct proportions and no duplicated rows; physical
observation found the animation smooth.

A post-test kernel-log scan found no GPU hang, GMU recovery, Adreno fault, or
IOMMU fault. This extends the earlier headless Vulkan result to real KMS
scanout.

## Weston and input

Weston 14.0.2 started with its DRM backend and GL renderer. Its log confirmed:

```text
DRM atomic modesetting: supported
GBM modifiers: supported
renderer: OpenGL ES 3.2, freedreno FD640
output: DSI-1, 1440x3120, 60.0 Hz, preferred and current
```

Libinput associated all four input devices with `DSI-1`:

- Power;
- Volume Down;
- Volume Up;
- Samsung S6SY761 touchscreen.

The Weston desktop and terminal rendered at the correct orientation. Touches
inside the terminal window tracked the displayed content correctly and were
physically confirmed to respond.

## Plasma Mobile

The live postmarketOS root installed
`postmarketos-ui-plasma-mobile-6-r10` and
`postmarketos-ui-plasma-mobile-openrc-6-r10`, which provide Plasma Mobile
6.7.3 and select `/usr/share/wayland-sessions/plasma-mobile.desktop` for
`tinydm`.

Launching the desktop directly from SSH was intentionally retained as a
negative control. KWin could see the render node but rejected the primary KMS
node because the SSH login was not an active local seat:

```text
kwin_core: Failed to open /dev/dri/card0 device (Operation not permitted)
kwin_wayland_drm: No suitable DRM devices have been found
```

Starting the packaged `tinydm` service created the expected PAM/elogind local
session on active `seat0`. KWin then acquired `card0`, started Xwayland,
`plasmashell`, the Plasma Mobile initial-start flow, and the lock screen. The
graphical shell filled the panel at the correct orientation. The user unlocked
the session, navigated the interface, and confirmed that it was smooth and
that touch input responded correctly.

No new GPU, GMU, or IOMMU fault appeared after Plasma Mobile started. KWin
does emit non-fatal `Could not create udmabuf: Invalid argument` messages, and
the kernel had three earlier non-fatal DPU `encoder is disabled` messages over
the long-running boot. Neither prevented KMS rendering or compositor use.

## Packaged application set

Device package revision `3-r4` adds an install-if subpackage for Plasma Mobile.
It selects Discover with its Flatpak backend, Konsole, Angelfish, Dolphin,
Kalk, KClock, KWeather, Koko, Merkuro, Okular Mobile, Plasma Dialer, Spacebar,
Megapixels, and the supporting Flatpak and user-directory packages. It also
selects `polkit-elogind`, which lets the active local Plasma session manage
NetworkManager instead of inheriting the no-elogind PolicyKit variant.

A clean strict pmbootstrap build produced:

| Output | Size | SHA256 |
|---|---:|---|
| `device-oneplus-hotdog-3-r4.apk` | 1,977 bytes | `ae537e2d0307b51ab21dfa97265757ca998ae7cde76a056d7982be26f6b97213` |
| `device-oneplus-hotdog-plasma-mobile-apps-3-r4.apk` | 1,378 bytes | `6be671884e1c6f94d138cba40454e5f5a5e6fba2e21257e321b11274931e25cc` |

## Conclusions and remaining work

The vertically repeated dense fbcon output is a console presentation issue,
not a general DSI scanout or panel-geometry failure. KMS clients and two
Wayland compositors produce a correct 1440x3120 image.

The following work remains before graphical support is complete:

- assemble and hardware-test a fresh pmaports image using the validated
  device-package application selection;
- validate repeated direct boots into `tinydm` without manual service startup;
- validate blank/unblank, suspend/resume, and touch wake;
- expose and validate the panel's 90 Hz mode separately from the accepted
  60 Hz baseline;
- investigate the non-fatal DPU IRQ and KWin udmabuf messages;
- keep Bluetooth, telephony, audio, cameras, sensors, and other peripheral
  work as separate subsystem changes.
