# Hardware support status

Last updated: 2026-08-26

This is the current evidence-based status of the physical OnePlus 7T Pro
HD1913. Historical K1, D-series and kexec experiments remain in
[bringup-history.md](bringup-history.md), [direct-boot.md](direct-boot.md) and
`docs/evidence/`; they are no longer the active validation queue.

## Tested baseline

| Item | Current value |
|---|---|
| Device | OnePlus 7T Pro, rear label HD1913; recovery reports HD1911 |
| Codename / SoC | `hotdog` / Qualcomm SM8150-AC |
| Bootloader | Unlocked OnePlus A/B bootloader |
| Active kernel line | Clean SM8150 Linux 6.17 migration candidate `linux-oneplus-hotdog-mainline617-clean` `6.17.0-r11`; 6.16 r181 remains the immutable oracle |
| Device package | `device-oneplus-hotdog` `3-r38` |
| Firmware package | `firmware-oneplus-hotdog` `20241212-r7` |
| Userspace | postmarketOS edge, OpenRC, Plasma Mobile |
| Boot path | OnePlus ABL -> Linux 6.17 -> standard pmOS initramfs -> writable rootfs -> Plasma Mobile |
| Recovery reference | Known-good slot/image, fastboot, pstore/ramoops and guarded Qualcomm `900e` capture; kexec is historical only |

The maintained endpoint is a current shared SM8150 kernel and upstream Hotdog
DTS, not a permanent device-specific 6.16 package. Ubuntu Touch/Lomiri on the
same mainline kernel is an additional roadmap target and has not started.

The support rows below remain physical-function claims established on the 6.16
oracle until the final 6.17 physical parity pass repeats them. The 6.17 r10
candidate passes direct boot, current-initramfs rootfs integration, electronic
subsystem enumeration and sustained NCM+ACM+SSH monitoring; this does not
silently promote untested physical behavior.

## Current support matrix

State meanings:

- **Working**: hardware-tested through a normal Linux interface.
- **Partial**: a useful path works, but required endpoints, stability or normal
  userspace integration remain incomplete.
- **Broken**: the attempted normal path fails reproducibly.
- **Not yet supported**: no usable standard interface has been validated.

| Subsystem | State | Current evidence and remaining gap |
|---|---|---|
| Direct kernel entry | Working | ABL directly starts the package-generated Linux 6.16 image; no downstream kernel or kexec bridge executes. |
| Rootfs / OpenRC / Plasma | Working | Writable split pmOS filesystems, `switch_root`, OpenRC, NetworkManager, SSH and accelerated Plasma Mobile boot automatically. The laboratory nested-GPT deployment is not the final installer layout. |
| A/B success and reboot | Working | `hotdog-qbootctl` marks the active slot successful synchronously after `localmount`; both slots are bootable/successful and the misleading generic oneshot is removed from the runlevel. `RESTART2("bootloader")` reaches protocol-valid bootloader fastboot, and `RESTART2("recovery")` reaches authorized root ADB. A native pmOS recovery still needs completion. See [A/B retry regression](evidence/2026-08-17-ab-slot-retry-regression.md) and [ICE/reboot-mode validation](evidence/2026-08-25-ufs-ice-reboot-mode.md). |
| UFS and RAM map | Working | UFS survives raw/random I/O, a multi-gigabyte Flatpak deployment and the former pressure reproducer after completing the stock reserved-memory union. |
| UFS ICE | Working | The recorded failure was stale: on the running device `1d90000.crypto` binds to `qcom-ice` and `gcc_ufs_phy_ice_core_clk` runs at 300 MHz. Only the link was missing -- upstream `sm8150.dtsi` carries `qcom,ice = <&ice>` and the board deleted the property. The corrected image is now flashed and survives normal boot plus a bootloader round-trip; UFS mounts the rootfs and blk-crypto exposes AES-256-XTS and the full profile. This proves ICE operation, not encryption of the current rootfs. |
| Apps SMMU | Partial | DWC3 stream `0x140` and UFS stream `0x300` work in translated domains; complete client coverage and removal of all temporary bypasses remain. |
| USB device / recovery | Partial | The current initramfs creates NCM and ACM together before the first UDC bind; NCM networking, SSH and ACM remain continuously available through rootfs startup. Remote bootloader and recovery selection are validated through `RESTART2`; the existing recovery exposes authorized root ADB. A native pmOS recovery and final installer rollback flow remain. |
| USB ACM serial | Working | `ttyGS0` provides a real bidirectional root session at a stable host by-id path. The rootfs service only starts its getty and never unbinds configfs; ACM and NCM remained present for the full 15-minute r10 hardware monitor and a subsequent normal reboot. Two independent host reconnects exchanged unique TX/RX markers and read the expected kernel release. |
| Internal display | Partial | Correct 1440x3120 KMS, fixed 60 Hz and selectable 90 Hz work at the function level. On 2026-08-20, `e566d5d4-r2` produced transient corrupted DSC scanout that recovered immediately after lock/unlock. The post-recovery trace counted 48 `dsi_err_worker` status-5 FIFO/timeout events and Samsung DSC panel reinitializations at 90 Hz, with no DPU underrun. No display-related DRM/DSI/panel source or config delta was found; r4/v4 tracing/debug does not prove causality. Canonical state: `TRANSIENT_RECOVERED / NEEDS_FOLLOWUP`. See [display regression 01](evidence/2026-08-20-display-regression-01.md) and [DSI/DSC transport errors](evidence/2026-08-17-dsi-dsc-transport-errors.md). |
| GPU | Working | Adreno 640, GMU, Freedreno/Turnip, Vulkan, `kmscube`, Weston and Plasma scanout work. Sustained mixed load and suspend/resume remain stability gates. |
| Touch and keys | Partial | S6SY761 touch plus Power, Volume Up and Volume Down work in Plasma. The alert slider is separately validated as Working. After suspend, elogind seat ownership and S6SY761 sensing remain follow-up items for this aggregate row. |
| Alert slider | Working | The generic `gpio-keys` `ABS_SND_PROFILE` device and `fbd-alert-slider` bridge provide Silent, Vibrate and Ring. GPIO27 was initially intermittent at the lower detent, but the exact OxygenOS downstream control reported `0,1,1` / down and an immediate return to mainline retained GPIO27 low for 50/50 reads, disproving a missing mainline electrical enable. |
| Wi-Fi | Partial | WCN3990 scans and associates on both bands with Internet reachability. The link now survives system suspend: 0 losses over 30 real `s2idle` cycles, against 13 of 15 before. That needed `device_init_wakeup()` in `ath10k_snoc`, without which `ath10k_snoc_hif_suspend()` always returned `-EPERM` and mac80211 tore the connection down every cycle, plus WoWLAN triggers configured from userspace. `wlan0` also keeps its address across a modem crash now, from the two MSA reclaim patches. Factory MAC, sustained throughput and AP/roaming remain, and copy engine 2 armed as a wake source means ordinary traffic can wake the phone. |
| SLPI sensor DSP | Working | Sensors stream and SensorProxy answers. The watchdog cycle that killed the user protection domain every 40.17 s is gone: 0 crashes and 0 QMI decode failures over 315 s, against 6 and 6 in the first 289 s before. It was never an SLPI fault -- `console=ttyGS0` put the kernel console on the USB gadget, `printk` blocked whenever no host was draining it, and QMI answers arrived past the DSP's watchdog. See [SLPI watchdog](evidence/2026-08-27-slpi-watchdog-every-40-seconds.md). |
| Bluetooth | Working | Scan, pair and HID input validated on `r13`: `crbtfw21.tlv` and `crnv21.bin` download at boot, `hci0` is `UP RUNNING`, an LE scan lists nearby devices, and an Xbox Wireless Controller reaches `Paired/Trusted/Connected` over an `AUTH ENCRYPT` LE link. `/dev/input/js0` delivered 2484 real axis events against 23 init events, with 0 HCI errors. The root cause was never firmware or the driver: the board declared no `serial`/`hsuart` alias, so `of_alias_get_id()` returned `-ENODEV`, `serial@c8c000` never probed and no controller was ever created. Two `hci_qca` bugs found on the way are also fixed. Reloading `hci_uart` restores `hci0` on 3/3 cycles and the controller reconnects on its own; the earlier failure belonged to one degraded boot. The address is locally administered but stable across boots and reloads, and BlueZ reports no missing configuration. See [Bluetooth](evidence/2026-08-26-bluetooth-two-bugs-behind-one-dead-controller.md). |
| Audio | Partial | Both internal speakers and the handset microphone work through packaged UCM, restored on 6.17 after the base tree's new tfa9872 driver claimed `nxp,tfa9874` and displaced the validated tfa9874 driver, overwriting its own DAPM widgets and silencing both amplifiers. Earpiece, remaining microphones, headset/USB-C detection, Bluetooth/call/DP audio, capture controls and protection telemetry remain. |
| USB-C host / dock | Partial | Dual-role Type-C, powered host/sink and unpowered host/source modes, USB 3, storage, Ethernet enumeration and DisplayPort video at 2560x1440@60 work. VBUS source mode and storage were validated in both plug orientations, followed by gadget/SSH recovery without reboot. Ethernet traffic, broader HID/hotplug, DP audio and docked suspend remain. DP mode pruning is done: `msm_dp_bridge_mode_valid()` reused the wide-bus-halved pixel clock for link bandwidth, which accepted 2560x1440@120 at twice the two-lane HBR2 budget and tore the output. The two clocks are separated now, the mode is refused and the external display is clean. |
| Battery / SMB5 charging | Partial | Fuel gauge works. The exact SMB5 v4 candidate passed guarded charging, powered-dock sink and unpowered-dock source transitions in both Type-C orientations. A complete Plasma image also passed 180 s at a 900 mA SuperSpeed input limit with rising battery voltage. Termination, low battery, JEITA/thermal, off-mode, fast charge and suspend remain. |
| Thermal / suspend | Partial | The modem/Wi-Fi path passes thirty real `s2idle` cycles across two fresh boots, returning in 22.6 s against a 22 s alarm. Two root causes were power domains withdrawn from live clients: `sdhc_2` sat in the modem's domain and `qcom_pas_handover()` dropped proxy `cx`/`mss` votes. Wi-Fi also needs the `device_init_wakeup()` fix plus WoWLAN triggers. Aggregate suspend remains partial because Bluetooth can abort the cycle and camera/touch/session resume need broader coverage. See [proxy power domains](evidence/2026-08-19-proxy-power-domains.md) and [sdhc_2](evidence/2026-08-18-sdhc2-modem-power-domain.md). |
| Cameras | Partial | All four physical sensors capture through libcamera; rear focus and the Hall-bounded automatic IMX471 pop-up lifecycle work. CAMSS recovery, full AE/AWB/AF convergence, touch focus, production color, video/flash/OIS and broader apps remain. |
| Camera flash | Partial | Both PM8150L channels pass torch/strobe tests and visible light is physically confirmed. A standard `white:torch` function makes Plasma Mobile's existing flashlight quick setting available and it controls the light. Kernel r10 restores the r181 `v4l2-flash-led-class` module that the first migration config omitted; Plasma Camera control and capture synchronization still need retesting. |
| Flashlight / torch | Working | Plasma Mobile's standard quick-setting button discovers `white:torch`, turns the rear light on and off, and was physically confirmed. |
| IPA / rmnet | Working locally | New SM8150 IPA v4.1 data and binding bring up `rmnet_ipa0`; generic upstream acceptance and SIM data testing remain. |
| Modem / telephony | Partial | MPSS, RMTFS, QRTR, PD mapper and QMI services run. QMI exposes both physical SIM slots, joins each application to its physical ICCID, and the PIN path is slot-scoped. The correct PIN was accepted without consuming retries, but DMS was exposed before OxygenOS's PDC/MCFG bootstrap and the modem restarted. The matching OOS10 MPSS and its 69-profile MCFG catalog are installed; the read-only daemon confirms PDC is `NotProvisioned` and fails closed without a card. ModemManager is removed from both runlevels and D-Bus auto-activation is disabled so Plasma cannot race the pre-online owner. The IMS daemon now selects the IMS bearer profile for each populated subscription and drives the transactional executor from there: rmnet link, WDS sessions, P-CSCF and marked routing, with rollback on every failure path and a residue mask when something is genuinely left behind. With no card it fails closed at `unavailable` before any of that runs, so the establishment path is written and unit-tested but has never had a live bearer. Gated load/select/activate/verify, readiness handoff, registration, LTE data, SMS and calls remain. See [dual-SIM slot 2 and PIN routing](evidence/2026-08-24-dual-sim-slot2-pin.md), [the MCFG catalog reconstruction](evidence/2026-08-25-oxygenos-mcfg-catalog.md) and [the ModemManager gate](evidence/2026-08-25-modemmanager-preonline-gate.md). |
| GNSS | Partial | QMI LOC reports NMEA capabilities and starts/stops sessions. Standard location-service bridging, real coordinates, A-GPS and suspend policy remain. |
| NFC | Working | PN553/NCI reader mode works through the maintained Linux stack: a real ISO 14443-4 document is detected, activated, typed and exchanges ISO 7816-4 APDUs. Three consecutive rfkill down/up cycles recover cleanly. The observed `-5` read result is the expected unauthenticated ePassport BAC/PACE refusal. HCE and secure-element operation are explicitly outside the reader-mode scope. |
| Haptics | Working | The source-built AW8697 `FF_RUMBLE` driver identifies the controller. Physical vibration is confirmed across 10-100 percent strength, twenty repeated stop/start pulses, the normal `feedbackd` event path and a real 20-second suspend/resume cycle. |
| SLPI infrastructure | Working | SLPI boot, FastRPC, writable Hexagon service, registry regeneration, QRTR, SSC requests, event subscriptions and ULog forensics work end to end. The served tree carries socinfo, the OnePlus `project_name` and `oppoVersion` entries, and pre-created numbered registry files to sidestep the missing `O_CREAT`. The board identity is provisioned from `/proc/cmdline`, so `oppo_project` reads 19801 instead of 0. The sensor-compatible OxygenOS 10.0.13 `SLPI.HY.2.2-00083` image is now installed by a hash-gated private-source APK rather than an unowned manual copy; it takes hardware sensors from 1 to 7 and SEE data types from 4 to 41. See [the firmware version was the cause](evidence/2026-08-23-the-firmware-version-was-the-cause.md). |
| Accelerometer (LSM6DSM) | Working | Streams at 25 Hz through SEE. Gravity reads on Z lying flat and on Y held upright, so the axes are right. Its factory calibration is the real per-unit one, `ver:1`, restored after an earlier experiment regenerated it as zeros. |
| Gyroscope (LSM6DSM) | Working | Streams at 25 Hz, responds to rotation and settles back to rest. |
| Magnetometer (MMC5603) | Working | Plausible field magnitude that tracks movement. Bus scanning identified the fitted part as the MMC5603 at `0x30` — 2 transfers, 0 errors — rather than the AK0991x at `0x0c`, which NACKs. |
| IMU temperature | Working | Plausible die temperature. Capped at 5 Hz; 10 Hz and above return error 130. A single float, not a vector, which cost one wrong "dead sensor" reading before the parser was fixed. |
| Ambient light (TCS3701) | Working | Streams lux plus raw channels, reacts to occultation, and reaches userspace: `LightLevel` tracks the room through `net.hadess.SensorProxy`. |
| SAR (SX9324) | Working | Publishes a raw capacitance reading, `11865` on this unit, under event id **1026**. It was reported silent for a whole session because every tool here accepted only the generic event id 1025; see [the decoder that hid four sensors](evidence/2026-08-24-my-decoder-was-hiding-four-sensors.md). A coredump confirms the driver read `who_am_i = 0x23` and set its hardware-present flag. |
| Motion detect | Working | `amd` and `rmd` answer under event id **772**, `rmd` reporting `1.0`. Same cause as the SAR for the earlier "silent" reading. |
| Tilt detector | Working | Answers under event id **774** with an empty payload — the event is the signal, there is no value to carry. It fires rarely: a six-second window saw nothing and a fifteen-second one caught two, which is what made it look silent. Streaming mode returns error 130, correct for an on-change-only sensor. |
| Device orientation | Working | `device_orient` answers under event id **776**, reporting `4.0`. |
| Sensors in userspace | Working | Plasma Mobile auto-rotates. No bridge had to be written: postmarketOS ships `iio-sensor-proxy` 3.9 built against `libssc`, which speaks QMI to SEE directly and needs neither an IIO nor an input device. Two faults kept it dark. KWin never claimed the accelerometer because `autoRotation` was `InTabletMode` on a phone with no tablet-mode switch. And a claim landing before the driver registers is accepted and lost, since the daemon takes its D-Bus name before enumerating SEE — so [a boot gate](../helpers/hotdog-sensor-proxy-gate.sh) brings the chain up and only returns once `HasAccelerometer` is true. The reported orientation was half a turn out, corrected through `ACCEL_MOUNT_MATRIX` rather than the SEE registry, which every other consumer shares. See [userspace has a sensor path now](evidence/2026-08-23-userspace-has-a-sensor-path-now.md). |
| Proximity | Working | The passive TCS3701 channel heuristic was disproved by an uncovered dark-state false `near`; OxygenOS instead uses the ADSP Elliptic ultrasonic path, and so does this port. Sending the microphone index and suspend values OxygenOS writes before enabling the engine produced sensorhub parameter-id 16, which had never arrived. Measured end to end: 30 engine transitions, 29 of 29 reaching `net.hadess.SensorProxy`, median latency 0.72 s against the driver's 700 ms poll. The channel reports 2 rather than 1 because `iio-poll-proximity` scales its near level by 1.1 and a binary channel can never exceed its own threshold. Kernel, udev, SLPI gate and `hotdog-proximity-arm` are now package-owned; the private 448-byte calibration is restored from `persist` rather than published. It is a classifier for a head against the earpiece and ignores a flat object on purpose. Blanking during a real call remains unverified without a SIM. See [near and far](evidence/2026-08-25-proximity-reports-near-and-far.md) and [the protocol](evidence/2026-08-25-elliptic-protocol-from-oxygenos.md). |
| Range sensor | Not yet supported | STMVL53L1 wiring, calibration, driver and standard proximity/range integration remain. |
| Fingerprint | Not yet supported | Goodix `G_OPTICAL_18865_G3` in-display optical sensor, wired on tlmm 101 (supply), 131 (reset), 118 (interrupt) and 90 (vendor id), all currently unclaimed. There is no SPI node: the bus belongs to a Qualcomm TrustZone applet, and the stock HAL `libgf_ud_hal.so` reaches it through `libQSEEComAPI.so`, so no image ever reaches Linux. Blocked on a mainline QSEECom equivalent rather than on a missing driver. See [the fingerprint assessment](evidence/2026-08-19-fingerprint-goodix-udfps.md). |
| Ubuntu Touch / Lomiri | Not yet supported | The no-Halium architecture, rootfs boot, packaging, OTA/recovery and Lomiri session remain future roadmap phases. |

## Validated milestone evidence

- [Direct rootfs boot](evidence/2026-08-03-direct-mainline-rootfs.md),
  [USB](evidence/2026-08-03-direct-mainline-usb.md) and
  [package image](evidence/2026-08-03-mainline616-pmaports.md)
- [Graphical userspace](evidence/2026-08-04-mainline616-graphical-userspace.md),
  [touch](evidence/2026-08-04-mainline616-touchscreen.md) and
  [GPU](evidence/2026-08-04-mainline616-gpu.md)
- [Public image](evidence/2026-08-05-mainline616-public-image.md),
  [speakers](evidence/2026-08-05-mainline616-internal-speakers.md) and
  [microphone](evidence/2026-08-07-mainline616-microphone.md)
- [Four-camera status](evidence/2026-08-10-mainline616-camera-imx471-popup.md),
  [software reboot](evidence/2026-08-10-mainline616-software-reboot.md) and
  [A/B marking](evidence/2026-08-10-ab-slot-success.md)
- [GNSS](evidence/2026-08-10-gnss-qmi-loc.md),
  [NFC](evidence/2026-08-10-nfc-nxp-nci.md),
  [SLPI](evidence/2026-08-10-slpi-sensor-dsp.md) and
  [haptics](evidence/2026-08-11-haptics-aw8697.md)
- [IPA v4.1 scope](evidence/2026-08-12-ipa-v41-scope.md),
  [SMB5 v3](evidence/2026-08-13-smb5-v3-hardware-validation.md) and
  [Hexagon writable service](evidence/2026-08-13-hexagonrpcd-write.md)
- [SMB5 900 mA complete image](evidence/2026-08-16-smb5-complete-900ma.md),
  [SMB5 v4 dock and VBUS roles](evidence/2026-08-20-smb5-v4-dock-validation.md),
  [display regression 01](evidence/2026-08-20-display-regression-01.md),
  [A/B retry regression](evidence/2026-08-17-ab-slot-retry-regression.md),
  [DSI/DSC transport errors](evidence/2026-08-17-dsi-dsc-transport-errors.md),
  [suspend/resume defects](evidence/2026-08-17-suspend-resume-defects.md),
  [sdhc_2 in the modem's power domain](evidence/2026-08-18-sdhc2-modem-power-domain.md),
  [the IPA SSR notifier deadlock](evidence/2026-08-18-ipa-ssr-notifier-deadlock.md),
  [ath10k wakeup capability](evidence/2026-08-19-ath10k-wakeup-capability.md) and
  [the PAS proxy power domains](evidence/2026-08-19-proxy-power-domains.md)

## Current checkpoint

The modem/Wi-Fi suspend failure is closed, but aggregate suspend is not while
Bluetooth can still abort a cycle. Thirty real `s2idle` cycles across two fresh
boots ran with no modem crash and no Wi-Fi loss, where the first suspend of
every boot used to kill the modem six times out of six. Both fixed root causes
were the same mistake in different places, a power domain withdrawn from
something that still depended on it: `sdhc_2` was wired to the modem's domain
in `sm8150.dtsi`, and `qcom_pas_handover()` released the proxy `cx`/`mss` votes
at handover so `genpd_suspend_noirq()` took them down on the first suspend.

What remains on that front is smaller and named: the power cost of holding
`cx`/`mss` for the life of the modem is unmeasured, and downstream avoids it
with a ten second proxy timeout; Bluetooth still aborts cycles when `hci_uart`
is loaded; and the camera CCI, elogind session and touch sensing resume paths
each need their own work. The SLPI/physical-sensor boundary and ultrasonic
proximity are closed; the active frontier is the package-complete hardware
boot, normal GNSS/mobile-data integration and upstream revision.
Phase 0 of the [roadmap](roadmap.md) still requires every partial/broken row
above to reach Working and Stable.
