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

**Proven current state.** Direct boot receives the bootloader's complete
multi-gigabyte memory map. A full `r20` DDR capture found that the page
allocator treated `0x85e40000-0x85f00000` as RAM even though the HD1913 stock
DT includes it in `xbl_aop_mem`. Revision `r21` excluded that interval, but a
second full dump found the active Flatpak staging inode occupying
`0x99518000-0x99580000`, inside another stock-owned gap. A complete union
comparison found two intervals left: `0x89b00000-0x89d00000` from
`removed_regions` and `0x99517000-0x99600000` from `cdsp_regions`. Revision
`r22` reserves both. It direct-booted, passed a complete partition readback,
completed the formerly failing 3.7 GB Flatpak pull and deploy, and ran the
installed application without a Qualcomm transition. The historical K1 path
remains deliberately limited to the low bank.

**Accepted experiment.** Boot the exact `r20` kernel and userspace with all
three proven stock-owned gaps reserved, then repeat the 3.5 GB Flatpak import
that reliably entered `900e`. The verified 96 MiB A/B image is
`a54ed347dbb897a402f941301c5a8763bb0bd286e141eeff3a2d47094de1f45b`;
two strict source builds also produced the same `r22` pmaports package.

**Single-variable experiment.** Relative to `r21`, add only
`0x89b00000/0x200000` and `0x99517000/0xe9000` as `no-map`. Keep the exact
`r20` kernel, initramfs, command line, UFS SMMU stream, DMA32 aperture, and
every other DT property unchanged.

**Result.** The direct kernel reached the same postmarketOS root, reported the
reservations, and completed both pull and deployment. USB SSH, display, touch,
GPU, and Wi-Fi remained available; the installed game launched and ran.

**Package result.** The source-built `r22` kernel, DTB, modules, and standard
`boot-deploy` output direct-boot as `#23-oneplus-hotdog-mainline616`. A
synchronized 6 GiB buffered write and a subsequent 180-second runtime window
completed without a UFS error or USB transition. Keep the exact `r20` image as
the binary control while moving the packaged stack into a fresh image test.

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
complete at fixed 60 Hz: `kmscube` holds approximately 60 FPS, Weston reports a
preferred/current 1440x3120 `DSI-1` mode, and Plasma Mobile 6.7.3 starts through
the packaged `tinydm` path. Revision `r16` separately direct-boots with the
stock HD1913 90 Hz command and timing; DRM reports the active CRTC at
1440x3120, 90 Hz, and 415457 kHz under Plasma Mobile. See the
[graphical userspace evidence](evidence/2026-08-04-mainline616-graphical-userspace.md)
and [90 Hz display evidence](evidence/2026-08-04-mainline616-display-90hz.md).

**Next experiment.** Repeat direct boots into `tinydm` with the fixed 90 Hz
candidate while retaining SSH, then validate screen blank/unblank. After that
stable checkpoint, implement a panel-aware dynamic 60/90 Hz mode switch so the
DSI command and DRM timing change atomically.

**Success criteria.** Three direct boots reach a correctly oriented 1440x3120
Plasma Mobile session without manual service startup, duplicated rows, tearing,
or panel timeout. Touch remains aligned, Freedreno acceleration is selected,
blank/unblank is repeatable, and USB SSH remains stable. Dynamic refresh must
switch repeatedly in both directions without a blank panel or stale command.

**Risks and fallback.** A userspace atomic modeset can blank the only local
console even when the kernel remains healthy. Keep SSH active, preserve the
accepted `r15` image, and avoid changing panel commands, refresh rate, and
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

**Proven current state.** Revision `r13` starts MPSS with Hotdog's RMTFS
reservation, loads the WCN3990 firmware, binds `ath10k_snoc`, exposes `wlan0`,
and scans access points across 2.4 GHz and 5 GHz. Revision `r15` associates
through NetworkManager and reaches both the local gateway and an external IPv4
endpoint while Bluetooth is active. USB networking and SSH remain available.
The driver currently chooses a random MAC address.

**Next experiment.** Establish a stable device address and sustain
bidirectional traffic while recording firmware, SMMU, and disconnect events.
Keep the accepted display and USB gadget configuration unchanged.

**Success criteria.** Repeated boots preserve the same MAC address, association
survives sustained traffic, and Wi-Fi recovers after radio disable/enable. A
separate controlled suspend/resume test must preserve both Wi-Fi and USB SSH.

**Risks and fallback.** MPSS, RMTFS, Wi-Fi, and Bluetooth share radio resources.
Change only one power-management or address source at a time, and retain the
exact `r13` image as the no-Bluetooth radio fallback.

## 8. Bluetooth

**Proven current state.** Revision `r15` registers UART13 and the physical
WCN3990 controller, selects the packaged revision-21 firmware directly, and
supports BlueZ scans plus real HID connections. Separate 600-second windows
with Bluetooth blocked and with a controller connected completed cleanly. A
900-second window after powering off the connected controller also completed
without a USB transition. One earlier run entered Qualcomm `900e` without a
panic or system-suspend entry, so the isolated transition remains unexplained.

**Next experiment.** Repeat the original keyboard connection while recording
integrated IBS and pmsg state, then exercise repeated pair, disconnect, and
reconnect cycles. Attempt controlled system suspend only after the active path
remains repeatably stable.

**Success criteria.** Direct firmware loading, repeated scans, pairing, and a
sustained connection work without UART timeouts. Only then run one controlled
suspend/resume cycle with pstore capture prepared.

**Risks and fallback.** The current crash is correlated with sleep but is not
yet localized to Bluetooth, Wi-Fi, UFS, USB, or a shared power domain. Retain
`r15` as the fixed-60-Hz radio fallback and do not reset a phone exposed as
Qualcomm `900e` or `9008` from software.

## 9. Audio

**Proven current state.** Revisions `r23` through `r25` start the ADSP, bind
WCD9340 over SLIMbus and SoundWire, and register the SM8150 ALSA card with a
`MultiMedia1` playback/capture PCM. Revision `r26` selects the stock-derived
Hotdog `SLIMBUS_6_RX` to `AIF4_PB` playback backend. A silent 48 kHz stereo
S24_LE stream opens without a DSP or transport error while ADSP and MPSS remain
running. See the [r26 audio evidence](evidence/2026-08-05-mainline616-headphone-backend.md).

**Next experiment.** Package a minimal UCM2 profile and the stock-derived
WCD9340 wired-headphone controls. Keep the TFA98xx speaker amplifiers absent,
start with silence, and raise only the headphone path to a conservative level.

**Success criteria.** Plasma and ALSA select the same UCM profile, a short test
is audible through wired headphones without clipping or codec/DSP errors, and
route teardown returns every control and PCM to an idle state. Headset detect,
buttons, microphones, earpiece, and each external speaker amplifier require
separate follow-up tests.

**Risks and fallback.** Codec mixers can expose unsafe gain or connect an
unintended physical endpoint. Do not copy the complete Android mixer state.
Enable the minimum internal-headphone controls only, retain the silent r26
test as the control, and keep all external amplifier links disabled.

## 10. USB host mode

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
