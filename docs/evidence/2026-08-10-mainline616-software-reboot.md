# Mainline 6.16 software reboot

Kernel package revision `r108` fixes clean software reboot on the tested
OnePlus 7T Pro. Six consecutive software reboots returned to the direct-booted
postmarketOS system with USB networking and SSH. None enumerated as Qualcomm
Sahara crashdump (`05c6:900e`) or fastboot (`18d1:d00d`).

## R107 failure analysis

On revision `r107`, `sync; reboot` reproducibly completed most of the Linux
shutdown sequence and then exposed Qualcomm `05c6:900e`. A complete local RAM
capture was parsed with the exact matching `vmlinux`:

- boot image SHA-256:
  `6d493ddaa337bdbe76497943c67c55da27b69c3f34ef3c2904d989efe53bf68e`;
- matching `vmlinux` SHA-256:
  `aa199cb89e94f2bd9bcef093e2e270be683d026b602b121183370e88b76b4903`;
- matching build ID: `f0777bf5ad3d83871a9dd4447645c63976e94429`;
- captured kernel identity:
  `6.16.0-sm8150 #108-oneplus-hotdog-mainline616`.

The parser found no Linux panic or oops. The retained console showed an orderly
userspace and filesystem shutdown followed by DRM teardown warnings. Qualcomm
firmware state reported an FIQ, but did not identify a Linux crash. This made a
stale download-mode cookie or reset contract more likely than a userspace,
UFS, or kernel-panic failure. The RAM capture remains local because it contains
device memory.

## Root cause

The SM8150 device tree did not describe the TCSR download-mode register to the
Qualcomm SCM driver. Without `qcom,dload-mode`, SCM had to use a firmware call
whose result did not clear the physical cookie on this device before the warm
reset.

Qualcomm's downstream SM8150 tree identifies the register at `0x1fd3000`.
Mainline SM8250 and QCS615 describe the same layout as a TCSR syscon beginning
at `0x1fc0000`, with the SCM property selecting offset `0x13000`. Revision
`r108` applies that existing mainline contract to SM8150:

```dts
scm: scm {
	qcom,dload-mode = <&tcsr 0x13000>;
};

tcsr: syscon@1fc0000 {
	compatible = "qcom,sm8150-tcsr", "syscon";
	reg = <0x0 0x01fc0000 0x0 0x30000>;
};
```

The SCM driver now clears the download-mode bits through the secure I/O path
during probe and clean shutdown.

## R108 artifacts

| Artifact | SHA-256 |
|---|---|
| Patch `0098` | `f35fa2376a31333b8f90dccd360fa7f8c4edc5b3da8c4528d0392591540fef9d` |
| Kernel package `6.16.0-r108` | `eab46854807b39ca81e23279e3691e90a2c8a64bb4ac4825b0b7df349efe175b` |
| Kernel Image | `723c4884d975b7b62ee73a2e5941b71392b567b674f1ad3176fd9f2d20442dd8` |
| Hotdog DTB | `67f30bdccbec5e38d4f2fa25ddf149a3cf20268ea76c9ff7313cf158c75f290a` |
| AVB boot image | `981e855bc1e2ca98c510d932e8ac86f11b2be910c97187f40ce961952539e655` |

The AVB image passed `avbtool verify_image`, direct-booted as
`6.16.0-sm8150 #109-oneplus-hotdog-mainline616`, and exposed the expected two
big-endian cells in `/proc/device-tree/firmware/scm/qcom,dload-mode`.

## Hardware validation

Five consecutive cycles were run before installing the matching rootfs package.
Each cycle observed the normal USB gadget disappear, then return as
`18d1:d001` with `172.16.42.1` reachable. Four recorded preflight boot IDs were
different, proving that the cycles were real boots rather than a transient USB
rebind. A sixth cycle after upgrading the installed package from `r107` to
`r108` also returned normally and reported a fresh boot ID.

This validates normal software reboot. Reboot-to-bootloader and
reboot-to-recovery remain separate restart-reason tests.
