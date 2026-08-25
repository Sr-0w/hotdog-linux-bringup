# Source trees

Last reviewed: 2026-08-25

External repositories live under ignored `src/` paths and are never vendored.
Every published result records an exact commit; branch names alone are not
reproducible identities.

## Primary upstream targets

| Source | Role |
|---|---|
| [Linux mainline](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git) | Final kernel, driver, binding and Hotdog DTS target. Use the relevant maintainer tree when requested by `MAINTAINERS`. |
| [Linux next](https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git) | Integration and regression validation before or during review. |
| [postmarketOS pmbootstrap](https://gitlab.postmarketos.org/postmarketOS/pmbootstrap) | Image and package build tooling. |
| [postmarketOS pmaports](https://gitlab.postmarketos.org/postmarketOS/pmaports) | Device, firmware and shared Qualcomm kernel packages. |
| [postmarketOS Qualcomm SM8150 Linux](https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux) | SM8150 integration reference and historical K1 6.17 source. |
| [Mesa](https://gitlab.freedesktop.org/mesa/mesa) | Freedreno/Turnip userspace. |
| [libcamera](https://git.libcamera.org/libcamera/libcamera.git/) | Camera pipeline and controls. |
| [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git) | Redistributable firmware upstream where licensing permits. |
| [UBports](https://gitlab.com/ubports) | Ubuntu Touch rootfs, packaging, recovery, OTA and system integration target. |
| [Lomiri](https://gitlab.com/ubports/development/core/lomiri) | Native Lomiri/Mir userspace target for the no-Halium path. |

## Hardware reference sources

| Source | Use and limitation |
|---|---|
| [OnePlus SM8150 kernel](https://github.com/OnePlusOSS/android_kernel_oneplus_sm8150) | GPL vendor wiring, power sequence and driver reference; Android 4.14 code is not loadable into mainline unchanged. |
| [LineageOS hotdog device tree](https://github.com/LineageOS/android_device_oneplus_hotdog) | Partition, firmware and userspace configuration reference. |
| [LineageOS SM8150 kernel](https://github.com/LineageOS/android_kernel_oneplus_sm8150) | Downstream comparison and rescue reference only. |
| [ClearStaff Hotdog Linux](https://github.com/ClearStaff/linux-sm8150-mainline-hotdog) | Hardware-validated Linux 6.16 bring-up baseline being cleaned for upstream. |
| [sm8150-linux-mainline pmaports](https://github.com/sm8150-linux-mainline/pmaports) | Existing SM8150 packaging and device reference. |
| [BotchedRPR Halium kernel](https://github.com/BotchedRPR/hotdog-halium-kernel) | Historical comparison only; Halium is not a project endpoint. |

The local OxygenOS reference set also includes a publicly downloaded OnePlus
7T Pro update archive containing EU, NA and IN OxygenOS 11.0.9.1 and 12 F.22
packages. It is an ignored reference input, not a vendored source. Record the
exact archive/package hash in the evidence that uses it; see the
[Elliptic proximity port](evidence/2026-08-24-elliptic-ultrasonic-proximity-port.md).

OxygenOS partitions may supply firmware and calibration at runtime when the
licence and upstream Linux ABI permit. Kernel modules built for Android 4.14,
Android HALs and private binaries are never treated as mainline drivers.

## Bootstrap behavior

```bash
./scripts/bootstrap-sources.sh --sm8150-k1
```

Add `--kernel-mainline` or `--linux-next` when preparing upstream work. The
script fetches/clones without resetting local branches or discarding changes.
Ubuntu Touch/Lomiri source bootstrap will be added only after the phase-15
architecture is agreed; do not introduce a private Halium replacement.
