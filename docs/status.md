# Hardware support status

Last updated: 2026-08-17

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
| Active kernel line | Mainline-oriented Linux 6.16 reference package, currently `linux-oneplus-hotdog-mainline616` `6.16.0-r177` |
| Device package | `device-oneplus-hotdog` `3-r23` |
| Firmware package | `firmware-oneplus-hotdog` `20241212-r5` |
| Userspace | postmarketOS edge, OpenRC, Plasma Mobile |
| Boot path | OnePlus ABL -> Linux 6.16 -> standard pmOS initramfs -> writable rootfs -> Plasma Mobile |
| Recovery reference | Known-good slot/image, fastboot, pstore/ramoops and guarded Qualcomm `900e` capture; kexec is historical only |

The maintained endpoint is a current shared SM8150 kernel and upstream Hotdog
DTS, not a permanent device-specific 6.16 package. Ubuntu Touch/Lomiri on the
same mainline kernel is an additional roadmap target and has not started.

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
| A/B success and reboot | Working | `qbootctl` marks the active slot successful; six clean software reboot cycles returned to pmOS. This regressed silently between 10 and 17 August because the complete images reused a rootfs predating the fix, and retry exhaustion left slot B unbootable; see [A/B retry regression](evidence/2026-08-17-ab-slot-retry-regression.md). The running rootfs is repaired, the image pipeline is not. Direct recovery-mode selection and final installer rollback still need completion. |
| UFS and RAM map | Working | UFS survives raw/random I/O, a multi-gigabyte Flatpak deployment and the former pressure reproducer after completing the stock reserved-memory union. |
| UFS ICE | Broken | UFS boots only without the ICE dependency; clock, power, probe-order and SMMU integration remain. |
| Apps SMMU | Partial | DWC3 stream `0x140` and UFS stream `0x300` work in translated domains; complete client coverage and removal of all temporary bypasses remain. |
| USB device / recovery | Partial | NCM networking and SSH are stable and ACM enumerates. Interactive ACM, all reboot modes and the final non-laboratory recovery flow remain. |
| Internal display | Partial | Correct 1440x3120 KMS, fixed 60 Hz and selectable 90 Hz work. Spontaneous DSI transport error bursts drain all four HS lanes and desynchronise the DSC stream into unreadable noise, with no driver recovery path; a panel re-init clears it. Not caused by brightness, input or compositor load. See [DSI/DSC transport errors](evidence/2026-08-17-dsi-dsc-transport-errors.md). |
| GPU | Working | Adreno 640, GMU, Freedreno/Turnip, Vulkan, `kmscube`, Weston and Plasma scanout work. Sustained mixed load and suspend/resume remain stability gates. |
| Touch and keys | Partial | S6SY761 touch plus Power, Volume Up and Volume Down work in Plasma. After a suspend cycle all input is lost, from two independent causes: the elogind session on `seat0` stays inactive so the compositor holds no input device, and `s6sy761_resume()` never re-enables sensing. Both are diagnosed and the driver bug is patched; all contact slots and alert slider remain. |
| Wi-Fi | Partial | WCN3990 scans and associates on both bands with Internet reachability. `wlan0` now keeps its address across a modem crash, measured over four suspend cycles that each ended in one, where every cycle used to leave it down; this needed the two MSA reclaim patches, see the evidence file. Resume itself still costs 30.4 s whenever the modem is dead, since one QMI transaction burns the full `ATH10K_QMI_TIMEOUT`. Factory MAC, sustained throughput and AP/roaming remain. |
| Bluetooth | Broken | The controller no longer initialises: `hci0` stays `DOWN` with a locally administered address and no firmware download. Worse, `qca_suspend()` times out after ~3.3 s and aborts every system suspend, and `rmmod hci_uart` panics the kernel in `qca_power_shutdown()`. See [suspend/resume defects](evidence/2026-08-17-suspend-resume-defects.md). |
| Audio | Partial | Both internal speakers and the handset microphone work through packaged UCM. Earpiece, remaining microphones, headset/USB-C detection, Bluetooth/call/DP audio, capture controls and protection telemetry remain. |
| USB-C host / dock | Partial | Dual-role Type-C, powered host mode, USB 3, storage, Ethernet enumeration and DisplayPort video at 2560x1440@60 work. Unpowered VBUS, broader HID/hotplug, DP mode pruning, DP audio and docked suspend remain. |
| Battery / SMB5 charging | Partial | Fuel gauge works. The exact SMB5 v3 candidate passed guarded 180 s and 600 s runs plus a physical VBUS cycle. A complete Plasma image also passed 180 s at a 900 mA SuperSpeed input limit with rising battery voltage. Termination, low battery, JEITA/thermal, off-mode, fast charge and suspend remain. |
| Thermal / suspend | Broken | A real `s2idle` cycle enters and returns. The MPSS watchdog still fires on most cycles: 13 of 15 at `pm_test=devices` against 2 of 15 at `freezer` on an interleaved run, which places it in an ordinary `->suspend()` callback. The modem enters its low-power state and never leaves it, so the defect is in waking rather than in sleeping. A modem crash no longer wedges the phone: the IPA notifier deadlock and the Wi-Fi MSA reclaim are both fixed. See [suspend/resume defects](evidence/2026-08-17-suspend-resume-defects.md) and [the IPA deadlock](evidence/2026-08-18-ipa-ssr-notifier-deadlock.md). |
| Cameras | Partial | All four physical sensors capture through libcamera; rear focus and the Hall-bounded automatic IMX471 pop-up lifecycle work. CAMSS recovery, full AE/AWB/AF convergence, touch focus, production color, video/flash/OIS and broader apps remain. |
| Camera flash | Partial | Both PM8150L channels register and pass electrical torch/strobe tests without a reported fault. Visible-light confirmation, stock-current calibration and camera synchronization remain. |
| IPA / rmnet | Working locally | New SM8150 IPA v4.1 data and binding bring up `rmnet_ipa0`; generic upstream acceptance and SIM data testing remain. |
| Modem / telephony | Partial | MPSS, RMTFS, QRTR, PD mapper and QMI services run; the modem reports revision and signal without a SIM. SIM/PIN, registration, LTE data, SMS, calls and IMS remain untested. |
| GNSS | Partial | QMI LOC reports NMEA capabilities and starts/stops sessions. Standard location-service bridging, real coordinates, A-GPS and suspend policy remain. |
| NFC | Partial | PN553/NCI reader mode works through a maintained Linux stack: a real ISO 14443-4 document is detected, activated, typed and exchanges ISO 7816-4 APDUs. The observed `-5` read result is the expected unauthenticated ePassport BAC/PACE refusal, not a transport failure. Clean down/up recovery, HCE and secure-element scope remain. |
| Haptics | Partial | The source-built AW8697 `FF_RUMBLE` driver identifies the controller and physical vibration is confirmed. Strength range, repeated stop/start, feedbackd and suspend remain. |
| SLPI infrastructure | Partial | SLPI boot, FastRPC, writable Hexagon service, registry regeneration, QRTR, SSC requests and ULog forensics work end to end. Only infrastructure SUIDs are published. |
| Motion/light sensors | Broken | LSM6DSM, MMC5603x and TCS3701 drivers publish no physical SUID. Both tested firmware sets reject the QUP1/QUP2-to-EBI1 ICB routes with `ICBARB_ERROR_NO_ROUTE_TO_SLAVE`; the next control is the current firmware/userspace on downstream 4.14 with stock DTBO. |
| Range sensor | Not yet supported | STMVL53L1 wiring, calibration, driver and standard proximity/range integration remain. |
| Fingerprint | Not yet supported | Transport, firmware/TEE dependency, UDFPS illumination and fprintd integration remain. |
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
  [A/B retry regression](evidence/2026-08-17-ab-slot-retry-regression.md),
  [DSI/DSC transport errors](evidence/2026-08-17-dsi-dsc-transport-errors.md) and
  [suspend/resume defects](evidence/2026-08-17-suspend-resume-defects.md)

## Current checkpoint

The active frontier is suspend/resume, which is the widest open gate: a real
`s2idle` cycle returns, but the MPSS watchdog, Wi-Fi, camera CCI, the elogind
session and touch sensing each fail on resume, and charger wakeups truncate
test cycles while USB is attached. Alongside it sit the downstream-4.14 SLPI
route control, normal GNSS/mobile-data integration and upstream revision work. In parallel, phase 0 of the
[roadmap](roadmap.md) requires every partial/broken row above to reach Working
and Stable. Historical experiment details are evidence, not pending tasks.
