# Hardware enablement roadmap

This roadmap follows the
[direct-boot completion criteria](direct-boot.md#completion-criteria). The
accepted 6.16 `r6` pmaports baseline starts directly from the OnePlus
bootloader without the downstream kexec bridge, mounts the postmarketOS root
read-write, and retains USB NCM, USB ACM, SSH, the S6SY761 touchscreen, and the
Adreno 640 render path. It also registers Power, Volume Down, and Volume Up as
separate input devices. The current support claims are recorded in the
[hardware status matrix](status.md). Earlier K1 workarounds remain historical
diagnostic evidence in the [mainline bring-up record](mainline-bringup.md) and
the [K1 evidence record](evidence/2026-07-11-mainline-k1.md).

For every experiment below:

- start from the same hash-pinned direct-boot baseline;
- change only the stated variable;
- record the source commit, config hash, DTB hash, boot ID, and relevant logs;
- reject a result if the direct kernel identity or USB recovery channel is
  ambiguous;
- restore the preceding accepted DTB or boot image after a failed test, using
  the safeguards in [device safety](device-safety.md).

## 1. Complete RAM map

**Proven current state.** The K1 bring-up DTB limits `memory@80000000` to the
low bank at `0x80000000 + 0x3bb00000`. After reserved regions, approximately
448 MiB is available. The validated DTB also reserves the firmware-owned
`0x89d00000-0x8b700000` gap. The low-bank transform and exact hashes are
traceable through [mainline bring-up](mainline-bringup.md#1-kexec-low-bank-ram-window)
and the [DTB reproduction record](evidence/k1-dtb-source.md#transform-chain).

**Hypothesis.** The low-bank limit is a kexec handoff constraint rather than a
hardware limit. Direct boot can expose the complete downstream-observed memory
layout while retaining every `reserved-memory` exclusion.

**Single-variable experiment.** Change only the root memory `reg` property to
the observed three-bank map: low bank `0x80000000/0x3bb00000`, high bank
`0x180000000/0x100000000`, and bank `0xc0000000/0xc0000000`. Keep the firmware
gap, all other reserved regions, SMMU bypass, ICE removal, and kernel command
line unchanged.

**Success criteria.** The direct kernel reaches the same postmarketOS root;
reported RAM matches the physical map minus reservations; UFS and USB SSH stay
stable; and no early memory overlap, DMA, ramoops, or remoteproc fault appears.

**Risks and fallback.** An incomplete reserved-memory map can allow Linux to
overwrite firmware-owned memory before USB appears. On any early reset,
corruption warning, or unexplained device loss, restore the accepted low-bank
DTB. Do not investigate later subsystems on a partially trusted RAM map.

## 2. Apps SMMU

**Proven current state.** `15000000.iommu` identifies an SMMUv2 with 94 stream
matching groups and 56 context banks, then registration fails with `-EINVAL`.
K1 therefore removes `iommus` from UFS, QUP, and DWC3 and uses
`iommu.passthrough=1 arm-smmu.disable_bypass=0`; see
[the documented bypass](mainline-bringup.md#3-apps-smmu-failure).
`CONFIG_ARM_SMMU=y` and `CONFIG_QCOM_IOMMU=y` are already present in the K1
configuration.

**Hypothesis.** The mainline `dma-coherent` description conflicts with the
firmware-configured non-coherent table walk. Correcting that mismatch should
let the provider register before any client stream ID is reattached.

**Single-variable experiment.** Remove only `dma-coherent` from
`iommu@15000000`. Keep UFS, QUP, and DWC3 bypassed and retain both IOMMU command
line parameters so the experiment measures provider registration only.

**Success criteria.** The Apps SMMU registers without `-EINVAL`, creates its
IOMMU device, and introduces no new fault or regression in UFS, rootfs, or USB
gadget operation. After that result is accepted, reattach clients in separate
one-client experiments, starting with UFS stream ID `0x300`.

**Risks and fallback.** A provider can register yet use incorrect stream IDs
or firmware ownership rules. Do not reattach multiple clients together. Keep
the bypass DTB as the fallback and revert immediately on an SMMU fault,
translation fault, or loss of storage or USB.

## 3. UFS inline crypto

**Proven current state.** UFS works and exposes the Android partitions only
after the `qcom,ice` dependency is removed. With the dependency present,
`gcc_ufs_phy_ice_core_clk` remains off and `qcom-ice@1d90000` fails to probe.
The exact workaround is recorded in
[mainline bring-up](mainline-bringup.md#4-ufs-ice-dependency). The K1 config
already has `CONFIG_QCOM_INLINE_CRYPTO_ENGINE=y` and
`CONFIG_SCSI_UFS_QCOM=y`.

**Hypothesis.** Direct boot may preserve an ICE clock and power state that the
kexec transition loses. If it does not, the next fix belongs in the GCC/UFS
clock ownership and probe-ordering path rather than in storage discovery.

**Single-variable experiment.** On the accepted direct-boot DTB with Apps SMMU
still bypassed for UFS, restore only the UFS `qcom,ice` phandle. Change no
clock, regulator, UFS frequency, or SMMU property.

**Success criteria.** The ICE device probes without a stuck-clock or busy
error, UFS reaches its normal link state, every expected partition remains
visible, and the postmarketOS root mounts read-write across repeated boots.

**Risks and fallback.** A failed ICE dependency can defer UFS indefinitely and
remove both rootfs and USB userspace recovery. Restore the no-ICE DTB after the
first conclusive failure. If the direct result matches K1, investigate
`GCC_UFS_PHY_ICE_CORE_CLK` as a separate kernel experiment.

## 4. DRM, DSI, and panel

**Proven current state.** The 6.16 pmaports baseline initializes the native
SM8150 DPU, display clock controller, DSI host, 7 nm DSI PHY, TE signal, DSC,
and the OnePlus Samsung command-mode panel. DRM registers `fb0`, and fbcon
shows kernel plus initramfs output with the built-in Terminus 16x32 font. The
`r5` baseline also binds the Adreno GPU to the DPU. Physical KMS validation is
now complete at 60 Hz: `kmscube` holds approximately 60 FPS, Weston reports a
preferred/current 1440x3120 `DSI-1` mode, and Plasma Mobile 6.7.3 starts through
the packaged `tinydm` path. Both compositors show correct geometry without the
vertical repetition seen during dense fbcon scrolling. See the
[graphical userspace evidence](evidence/2026-08-04-mainline616-graphical-userspace.md).

**Next experiment.** Reproduce the Plasma Mobile package selection in a fresh
pmaports image and perform repeated direct boots into `tinydm` while retaining
SSH. Validate screen blank/unblank before changing the panel mode. Exposing the
90 Hz mode is a separate, later experiment on the accepted 60 Hz baseline.

**Success criteria.** Three direct boots reach a correctly oriented 1440x3120
Plasma Mobile session without manual service startup, duplicated rows, tearing,
or panel timeout. Touch remains aligned, Freedreno acceleration is selected,
blank/unblank is repeatable, and USB SSH remains stable. A later 90 Hz test must
retain those properties and return cleanly to 60 Hz.

**Risks and fallback.** A userspace atomic modeset can blank the only local
console even when the kernel remains healthy. Keep SSH active, preserve the
accepted `r8` image, and avoid changing panel commands, refresh rate, and
compositor configuration in the same experiment.

## 5. Samsung S6SY761 touchscreen

**Proven current state.** Hardware validation is complete for basic input. The
`r4` reference package enables QUPv3 wrapper 2, GPI DMA 2, I2C17, reset GPIO
54, level-low interrupt GPIO 122, `vreg_l1c_1p8`, and `vreg_l10c_3p3`. The
schema-valid S6SY761 node binds at address `0x48` and registers `event1`.

Taps and drags produced continuous 1440x3120-range coordinates, pressure,
contact dimensions, tracking IDs, and multiple slots. GPIO 122 recorded 729
S6SY761 interrupts during the test. The exact APK kernel and DTB booted
directly with USB SSH intact. See the
[touchscreen evidence](evidence/2026-08-04-mainline616-touchscreen.md).

Weston and Plasma Mobile now validate the graphical coordinate transform and
responsive touch on the correctly oriented native output. **Remaining
validation.** Exercise every advertised contact slot and test blank/unblank,
suspend/resume, and touch wake repeatedly. The driver emits a legacy
`ABS_X`/`ABS_Y` warning while correctly exposing the multitouch axes; keep that
distinction visible until power-state validation is complete.

**Risks and fallback.** Other regional `hotdog` variants may use different
rails or GPIO assignments. Keep the accepted `r4` boot image available and
change only one power, pinctrl, or suspend property per follow-up test.

## 6. Adreno 640 GPU

**Proven current state.** The reproducible `r5` package enables the Adreno 640
and GMU using the upstream SM8150 SMMU, clocks, interconnects, power domains,
OPP table, and reserved memory. The handset-specific ZAP path is the only
device override. MSM DRM binds `2c00000.gpu`, loads GMU firmware v2.0.261,
exposes `/dev/dri/renderD128`, and publishes six frequencies from 257 to
675 MHz. Turnip Mesa 26.1.6 completed two Vulkan workloads without a GPU, GMU,
or IOMMU fault. See the
[GPU evidence](evidence/2026-08-04-mainline616-gpu.md).

Physical-display validation is now complete at the basic runtime level:
`kmscube` holds approximately 60 FPS and both Weston and Plasma Mobile render
through Freedreno `FD640` without a GPU, GMU, or IOMMU fault. **Remaining
validation.** Exercise sustained mixed GPU/display load, then test
suspend/resume and repeated cold boots. Resolve or justify the non-fatal dummy
`vdd` and `vddcx` regulator warnings before upstream submission, and investigate
KWin's non-fatal udmabuf fallback.

**Risks and fallback.** GPU faults can wedge display scanout while USB remains
alive. Keep the exact `r4` touch image as a GPU-disabled fallback and preserve
the `r5` headless Vulkan test as a control when debugging compositor failures.

## 7. Wi-Fi

**Proven current state.** Firmware packaging exists, but runtime Wi-Fi is not
validated. The K1 DTS deliberately disables the WCN3990 Wi-Fi node, and the
working USB network path is the current remote channel. The support boundary
is recorded in [the status matrix](status.md#mainline-support-matrix).
`CONFIG_ATH10K_SNOC=m` is present, but firmware load, memory assignment,
clocks, and the Apps SMMU stream remain unproven together.

**Hypothesis.** After Apps SMMU registration and the Wi-Fi stream are trusted,
the existing WCN3990 description and packaged firmware are sufficient for an
initial SNOC probe without enabling Bluetooth or the modem.

**Single-variable experiment.** Enable only the Wi-Fi node on the accepted
SMMU baseline. Keep Bluetooth, modem, and unrelated remote processors disabled
and keep the firmware set unchanged.

**Success criteria.** Firmware loads without remoteproc or SMMU fault, a WLAN
interface appears, a passive scan completes, and association plus sustained
traffic work while USB SSH remains available. Reboot and suspend must not
leave the firmware path wedged.

**Risks and fallback.** Incorrect firmware, memory regions, or stream IDs can
crash the WLAN subsystem or fault the Apps SMMU. Disable Wi-Fi and retain USB
networking as the fallback. Do not combine first Wi-Fi validation with
Bluetooth or modem enablement.

## 8. USB host mode

**Proven current state.** USB 2 peripheral mode is proven through NCM, ACM,
and SSH. The K1 DTS forces `dr_mode = "peripheral"`, limits DWC3 to high speed,
and disables the QMP USB3/DisplayPort PHY. Host mode, VBUS sourcing, Type-C role
switching, SuperSpeed, and docks are unvalidated; see
[mainline bring-up](mainline-bringup.md#7-usb-gadget) and the
[status matrix](status.md#mainline-support-matrix).

**Hypothesis.** The DWC3 core and high-speed PHY can operate as a fixed USB 2
host before Type-C role switching, VBUS control, QMP PHY, or SuperSpeed support
is introduced.

**Single-variable experiment.** Change only DWC3 `dr_mode` from `peripheral`
to `host`, retaining the high-speed limit and HS PHY. Use an externally powered
USB 2 hub and one known low-power device so VBUS sourcing is not part of the
test.

**Success criteria.** The host controller registers, enumerates the known USB
2 device, and sustains data transfer without controller reset or SMMU fault.
Final USB completion requires separately validated Type-C role switching,
VBUS sourcing, peripheral recovery, QMP PHY/SuperSpeed, and representative
docks.

**Risks and fallback.** Fixed host mode removes the USB gadget, NCM, ACM, and
SSH recovery channel. Run it only after an independent console or proven
automatic restore path exists. Restore the peripheral-mode DTB after the test;
do not enable QMP, role switching, and VBUS in the same experiment.

## Upstream readiness

A subsystem is ready to leave this roadmap only when its temporary bypass is
gone, its DT binding validates, its kernel change is separated from pmaports
packaging, and repeated direct boots preserve storage and recovery channels.
Record regressions against other SM8150 devices before proposing generic
changes. The source/config/DTB chain must remain reproducible from the pinned
inputs described in the [DTB reproduction record](evidence/k1-dtb-source.md).
