# Roadmap

Last updated: 2026-08-11

## Final objective

The final objective is a fully usable OnePlus 7T Pro running postmarketOS with:

- a maintained mainline Linux kernel suitable for upstreaming;
- complete hardware support for the HD1913 test handset;
- a clean, maintainable `pmaports` submission;
- a normal postmarketOS installation and upgrade path;
- a 100% functional Plasma Mobile/postmarketOS userspace with no
  laboratory-only boot steps.

The project is not complete when an image merely boots. Each subsystem must be
hardware-tested, integrated into the normal package flow, documented, and
retested after the shared kernel and device packages are cleaned up.

## Current state

The public Linux 6.16 reference stack already direct-boots the physical HD1913
from the OnePlus bootloader, mounts a writable postmarketOS root filesystem,
starts OpenRC, exposes USB networking and SSH, and runs Plasma Mobile.

The following are currently working or hardware-validated:

- direct boot, persistent storage, clean software reboot, and recovery paths;
- native 1440×3120 display at stable 60 Hz, with 90 Hz mode selection working
  but wake reliability still incomplete;
- Adreno 640 acceleration through Freedreno/Turnip;
- S6SY761 touchscreen, Power, Volume Up, and Volume Down;
- basic Wi-Fi association and Bluetooth HID connectivity;
- internal stereo speakers and the handset microphone through packaged audio
  profiles;
- USB-C host mode, USB 3, and DisplayPort video output;
- battery fuel-gauge reporting;
- capture from all four cameras through libcamera and Plasma Camera;
- automatic IMX471 pop-up extension, capture, and retraction.

The remaining support gaps are tracked explicitly in
the [hardware status matrix](status.md). Camera capture is working, but AF/AE/AWB
convergence, touch-to-focus, production color calibration, and broader camera
application testing remain final camera-quality work. The ordered hardware
queue below starts with GNSS after the camera capture milestone.

## Ordered execution plan

### 1. GNSS / location

| Subsystem | Function | Current state |
|---|---|---|
| GNSS | Location | Engine answers QMI; userspace path blocked behind IPA. |

The modem's GNSS engine works. With `pd-mapper` started, the LOC service answers
over QRTR: NMEA types are readable and location sessions start and stop cleanly.
The rest of the modem answers too, reporting its revision, signal strength, and
that no SIM is inserted.

What is missing is the bridge to a location service, and it is not GNSS-specific.
`gnss-share` has only serial and ModemManager backends, ModemManager discards the
modem with `Failed to find a net port in the QMI modem`, and that net port is
`rmnet` over IPA. Upstream IPA has no SM8150 support and neither mainline nor
`linux-next` carries data for it.

So GNSS is not independent: it sits behind the same IPA work as mobile data.
Either port IPA for SM8150, which unlocks data, ModemManager, and GNSS together
and is the change that belongs upstream, or add a QMI backend to `gnss-share`,
which is smaller but GNSS-only. See the
[GNSS QMI evidence](evidence/2026-08-10-gnss-qmi-loc.md).

Exit criterion: a repeatable fix is available through the normal postmarketOS
location stack after boot and resume.

### 2. Sensors

| Subsystem | Function | Current state |
|---|---|---|
| Sensors | Motion / rotation / proximity | Mainline integration remains to be implemented and hardware-tested. |

Identify the sensor hub and individual sensors, add the required mainline
drivers and firmware, expose IIO events, and integrate orientation, proximity,
and motion into Plasma Mobile.

Exit criterion: accelerometer, gyroscope, magnetometer, light, proximity, and
the relevant motion events work through standard Linux interfaces and survive
repeated boots.

### 3. NFC

| Subsystem | Function | Current state |
|---|---|---|
| NFC | NFC / secure-element path | PN553 controller, board RF configuration and polling are hardware-validated; tag discovery and secure-element support remain open. |

Identify the controller and bus, package only redistributable firmware, bring up
reader mode, and document the secure-element and payment limitations separately.

Exit criterion: NFC tag detection and reader operation work in userspace, with
any secure-element limitation explicitly documented.

### 4. Haptics

| Subsystem | Function | Current state |
|---|---|---|
| Haptics | AW8697 | Controller identity and wiring are hardware-confirmed. Revision `r143` adds a source-built `FF_RUMBLE` driver and passes the strict package build; vibration and feedbackd remain untested. |

The controller answers at `0x5a` with chip ID `0x97`; the stock tree identifies
GPIO 116 as reset, GPIO 24 as interrupt, and the HD1913 as the 170 Hz actuator
profile. The initial driver uses continuous mode and the normal OxygenOS drive
limit without requiring proprietary effect firmware. Validate low-strength and
full-strength pulses, repeated stop/start behavior and input force feedback,
then connect it to feedbackd without making vibration dependent on a vendor
Android service.

Exit criterion: notification and user-interface haptics work repeatedly through
the normal postmarketOS feedback stack.

### 5. Range sensor

| Subsystem | Function | Current state |
|---|---|---|
| Range sensor | STMVL53L1 laser rangefinder | Driver/integration work remains. |

Confirm the I2C address, interrupt, regulators, and calibration data. Bring up
the STMVL53L1 through an appropriate mainline interface and integrate it with
the proximity or sensor service where appropriate.

Exit criterion: range measurements are stable, exposed through a standard
interface, and safe across suspend and resume.

### 6. Fingerprint

| Subsystem | Function | Current state |
|---|---|---|
| Fingerprint | In-display fingerprint reader | Plasma/fprintd can provide the userspace authentication path; Hotdog still needs sensor/firmware integration and UDFPS display-illumination coordination. |

Identify the reader, vendor firmware, transport, TEE dependency, and display
illumination sequence. Implement the smallest maintainable integration possible,
and keep enrollment, authentication, suspend, and lock-screen behavior separate
in the test matrix.

Exit criterion: enrollment and unlock work through fprintd/Plasma, including
the required display illumination, or every unsupported vendor dependency is
proven and documented rather than hidden behind an Android HAL.

### 7. Telephony and mobile data

The MPSS and QRTR/RMTFS foundations are present, but the actual modem service is
not yet hardware-validated.

Complete the modem path in this order:

1. modem enumeration and firmware lifecycle;
2. SIM detection and PIN handling;
3. LTE data through ModemManager and NetworkManager;
4. SMS send and receive;
5. voice calls and in-call audio;
6. VoLTE/IMS only if the hardware and upstream userspace make it practical.

Exit criterion: SIM, data, SMS, and calls work through normal postmarketOS
services without losing USB recovery or breaking suspend.

### 8. Audio completion

The internal stereo speakers and handset microphone are working. The remaining
audio work is to finish the physical endpoints and normal application path:

- earpiece speaker;
- wired USB-C/headset paths and detection;
- remaining analogue and digital microphones;
- capture volume and protection telemetry;
- echo cancellation and noise-reduction policy;
- DisplayPort audio;
- complete ALSA UCM and PipeWire/WirePlumber profiles.

Exit criterion: playback, capture, calls, earpiece, headphones, speakerphone,
and external-display audio work through normal Plasma applications with safe
power-down and conservative gain defaults.

### 9. Power, charging, thermal, and suspend/resume

The fuel gauge and conservative charger limits are working, but charging policy,
thermal behavior, and full suspend remain incomplete. The touchscreen resume
failure currently blocks reliable system suspend.

Complete this phase in dependency order:

1. touchscreen reset and resume;
2. display blank/unblank and touch wake;
3. `s2idle` and repeated suspend/resume with USB, Wi-Fi, Bluetooth, and audio;
4. charging transitions, termination, low-battery behavior, and Warp/USB limits;
5. thermal zones, throttling, and sustained CPU/GPU workloads;
6. stable dynamic 60/90 Hz behavior after wake.

Exit criterion: the handset can suspend, resume, charge, throttle, and recover
reliably over repeated cycles without losing storage, display, radios, or SSH.

### 10. USB-C and dock completion

USB-C host mode, USB 3, and DisplayPort video are working. The remaining work is
to complete the role and power contract:

- Type-C role switching;
- source VBUS for an unpowered peripheral;
- peripheral mode recovery after host-mode tests;
- SuperSpeed and powered/unpowered dock combinations;
- USB mass storage, Ethernet, keyboard, mouse, and display regression tests;
- DisplayPort audio once the audio phase is ready.

Exit criterion: common powered and unpowered dock scenarios work without losing
the normal USB recovery path or requiring a laboratory DTB.

### 11. Storage and SoC integration cleanup

After the peripheral queue is complete, remove the remaining core bring-up
limitations:

- restore and validate UFS ICE;
- complete Apps SMMU client attachment for UFS, QUP, DWC3, and other supported
  clients;
- replace temporary DMA, SMMU, reserved-memory, and firmware workarounds with
  correct device-tree descriptions;
- validate reboot to system, bootloader, and recovery from the direct image;
- repeat storage stress, graphics workloads, radios, audio, and suspend from a
  clean package-generated image.

Exit criterion: the normal kernel path no longer depends on the K1 forensic
package, downstream bridge, nested-GPT laboratory layout, or temporary bypasses.

### 12. Mainline kernel cleanup

Move the maintained device support into the shared
`linux-postmarketos-qcom-sm8150` package and keep the Hotdog-specific changes
small and reviewable.

1. separate generic SM8150 changes from Hotdog DTS and device quirks;
2. remove the downstream 4.14/kexec bridge from the supported boot path;
3. remove binary DTB mutation and laboratory-only scripts;
4. run schema validation, `dtbs_check`, kernel configuration checks, and clean
   reproducible builds;
5. test the resulting kernel against a current supported mainline baseline;
6. prepare focused upstreamable Linux patches with regression notes.

Exit criterion: a clean shared-kernel build boots the exact device package on
hardware and preserves the completed support matrix.

### 13. pmaports submission

Prepare the final `device/testing` submission only from the maintained package
architecture:

- `linux-postmarketos-qcom-sm8150` for the shared kernel;
- `device-oneplus-hotdog` for device metadata and narrowly justified runtime
  integration;
- `firmware-oneplus-hotdog` only for firmware with documented provenance,
  ownership, checksums, and redistribution terms.

The submission must build from a clean checkout, pass current `pmaports` policy
checks, generate the boot image through the normal device flow, direct-boot
that exact output, and publish only reproducible hashes and permitted evidence.
The nested `userdata` GPT, fixed-size AVB wrapper used only for laboratory
recovery, permissive `doas`, custom watchers, and unvalidated convenience
policies must not be submission requirements.

Exit criterion: a reviewer can build, install, boot, recover, and upgrade the
device using normal postmarketOS and pmaports workflows.

### 14. Final postmarketOS validation and release

Run the complete acceptance matrix on the final shared-kernel and pmaports
packages:

- first install, reboot, upgrade, rollback, and recovery;
- Plasma Mobile display, touch, GPU, cameras, sensors, radios, audio, haptics,
  fingerprint, charging, suspend, and dock workflows;
- repeated cold boots and software reboots;
- normal application use without manual ALSA, mixer, GPIO, or camera commands;
- release artifacts, installation instructions, recovery guidance, and known
  limitations kept in sync with the hardware status matrix.

The project is complete only when the final image is a normal, reproducible,
maintainable postmarketOS device image with the intended OnePlus 7T Pro hardware
working end to end.

## Working references

- [Hardware support status](status.md)
- [Hardware enablement details](hardware-roadmap.md)
- [pmaports upstreaming plan](pmaports-upstreaming.md)
- [Build and test workflow](build-and-test.md)
- [Device safety rules](device-safety.md)
