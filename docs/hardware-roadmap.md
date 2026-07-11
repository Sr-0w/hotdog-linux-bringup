# Hardware enablement roadmap

This roadmap starts only after the
[direct-boot completion criteria](direct-boot.md#completion-criteria) are met.
The direct baseline must boot Linux 6.17 without the downstream kexec bridge,
mount the postmarketOS root read-write, and retain USB NCM, USB ACM, SSH, and a
tested recovery path. The current support claims are recorded in the
[hardware status matrix](status.md), while the temporary K1 workarounds and
their evidence are documented in the
[mainline bring-up record](mainline-bringup.md) and the
[K1 evidence record](evidence/2026-07-11-mainline-k1.md).

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

**Proven current state.** Early console output is lost and
`simple-framebuffer` cannot reserve its video memory. The mainline display
clock path and MDSS/DSI nodes are not enabled, while downstream proves a
working MSM DRM path for the Samsung DSC command-mode panel. The public K1 DTS
baseline contains only the bootloader framebuffer and panel geometry; see the
[tracked hotdog DTS patch](../patches/mainline-hotdog-k1-dts.patch) and the
[status matrix](status.md#mainline-support-matrix). The K1 config already
enables DRM MSM, DSI, and the 7 nm DSI PHY, but no mainline panel description
yet represents the complete OnePlus 1440x3120 60/90 Hz command sequence.

**Hypothesis.** The first independent blocker is display clock-controller
initialization. It can be validated without sending commands to the panel or
depending on the final panel driver.

**Single-variable experiment.** Remove only `disp_cc_sm8250_driver_init` from
the initcall blacklist. Leave MDSS, DSI0, DSI PHY0, and the panel disabled.

**Success criteria.** The display clock controller and its power domain probe
without timeout, reset, or regulator regression. Phase completion additionally
requires later one-step variants that enable the MDSS/DSI host without a
panel, then a 60 Hz-only panel driver and graph, before adding DSC mode changes
or 90 Hz. Final success is stable DRM scanout with console handoff and no loss
of USB SSH.

**Risks and fallback.** Incorrect clock or power-domain sequencing can reset
the device before remote logging starts; incorrect panel commands can leave a
lit, blank, or damaged display. Restore the display-blacklisted DTB on a clock
failure. Keep the panel disabled until host-only probing is clean, and retain
the downstream panel data as reference rather than copying its vendor driver.

## 5. Samsung S6SY761 touchscreen

**Proven current state.** The K1 DTS records I2C address `0x48`, interrupt GPIO
122, reset-related pinctrl, and the 3.0 V L17 rail, but both `i2c17` and the
touchscreen child are disabled. `CONFIG_TOUCHSCREEN_S6SY761=m` is available.
The mainline binding requires separate `vdd` and `avdd` supplies, so the
current one-supply node is not ready to enable. The baseline is visible in the
[tracked hotdog DTS patch](../patches/mainline-hotdog-k1-dts.patch).

**Hypothesis.** The QUP/I2C and pinctrl path is usable independently of the
touch driver; the remaining device-level work is an accurate 1.8 V/3.0 V
supply description and reset sequence.

**Single-variable experiment.** Enable only `i2c17`, leaving
`touchscreen@48` disabled. Confirm adapter registration and perform one
controlled address transaction at `0x48`; do not scan unrelated addresses.

**Success criteria.** The I2C controller probes without SMMU or pinctrl faults
and the known controller address acknowledges consistently. Final touchscreen
success requires a schema-valid two-supply node, clean S6SY761 probe, correct
1440x3120 coordinates, ten-contact reporting, suspend/resume, and no IRQ storm.

**Risks and fallback.** A missing logical rail can produce a false negative,
while incorrect reset or regulator sequencing can hold the controller or panel
subsystem in reset. Return `i2c17` to disabled after an inconclusive result and
add supplies or reset behavior one at a time.

## 6. Wi-Fi

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

## 7. USB host mode

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
