{{Infobox device

<!-- Main -->
| manufacturer = OnePlus
| name         = 7T Pro
| codename     = oneplus-hotdog
| model        =
| image        = File:hotdog-mainline.jpg
| imagecaption = OnePlus 7T Pro running postmarketOS with Plasma Mobile
| releaseyear  = 2019

| booting = yes
| status  = Close-to-mainline Linux 6.16, most core hardware working
| packaged = no
| category = testing


<!-- Hardware -->
| chipset = Qualcomm Snapdragon 855+ (SM8150-AC)
| cpu     = Octa-core (1×2.96 GHz Kryo 485, 3×2.42 GHz Kryo 485, 4×1.78 GHz Kryo 485)
| gpu     = Adreno 640
| display = 1440×3120 Fluid AMOLED, 6.67"
| storage = 256 GB UFS 3.0
| memory  = 8 / 12 GB
| architecture = aarch64
| wp_type =


<!-- Software -->
| originalsoftware = Android
| originalversion  = 10
| extendedversion  = 12
| optionalsoftware =
| status_fossbootloader = N


<!-- postmarketOS -->
| type          = handset
| pmoskernel    = 6.16
| whet_dhry     =
| genericdevice =
| optionalgenericdevice = no
| kernelpackage =
| devicepackage =
| firmwarepackage =


<!-- Warning / Note boxes / Miscellaneous -->
| supported      = yes
| prebuiltimages =
| boot_internal_storage = yes
| bootable_media =
| changearch =

| initial_MR =
| related_post =


<!-- Features -->
<!--
For each feature:
- Y = works as expected
- P = partially working
- N = does not work
- - = not applicable
- blank = not tested
-->

<!-- Main Features -->
| status_flashing = N
| status_uart     =
| status_usbnet   = Y
| status_emmc     = Y
| status_sdcard   = -
| status_battery  = Y
| status_screen   = P
| status_touch    = P
| status_keyboard = -
| status_touchpad = -
| status_stylus   = -
| status_mainline = Y


<!-- Multimedia Features -->
| status_3d     = Y
| status_dvb    = -
| status_audio  = P
| status_camera = P
| status_cameraflash = P
| status_irtx   = -
| status_irrx   = -


<!-- Connectivity Features -->
| status_wifi       = Y
| status_bluetooth  = P
| status_ethernet   = P
| status_gps        = P
| status_nfc        = P
| status_calls      = N
| status_sms        = N
| status_mobiledata = P


<!-- Miscellaneous Features -->
| status_fde         =
| status_usba        = -
| status_sata        = -
| status_otg         = Y
| status_hdmidp      = Y
| status_fingerprint = N


<!-- Sensors -->
| status_accel       = Y
| status_magnet      = Y
| status_light       = Y
| status_proximity   = Y
| status_hall        = Y
| status_haptics     = P
| status_barometer   = -
| status_powersensor = -

}}

== Description ==

The OnePlus 7T Pro is a 2019 flagship smartphone based on the Qualcomm Snapdragon 855+ (SM8150-AC).

A close-to-mainline Linux 6.16 port boots postmarketOS directly from the stock OnePlus bootloader. The normal boot path does not use the downstream Android kernel or a kexec chain. Hardware status on this page is validated on a European HD1913 handset; other variants require separate validation.

UFS storage, accelerated Adreno 640 graphics, Wi-Fi, USB-C, DisplayPort video, internal speakers and microphone, all four cameras, system suspend and the SLPI sensor stack are functional. Cellular telephony and several integration and lifecycle features remain under development.

The development tree and hardware-validation evidence are maintained in the [https://github.com/Sr-0w/hotdog-linux-bringup hotdog-linux-bringup repository].

{{Note|The development tree is newer than the currently published alpha image. Hardware listed as working on this page is not necessarily available in the latest public release image.}}

== Boot modes ==

With the device powered off, the following button combinations can be used:

{| class="wikitable feature-colors"
! Boot mode
! Power
! Vol+
! Vol-
|-
| Fastboot
| Y
| Y
| Y
|-
| Recovery
| Y
| N
| Y
|}

Fastboot can also be entered from Android when USB debugging is enabled:

<syntaxhighlight lang="shell-session">
$ adb reboot bootloader
</syntaxhighlight>

== Installation ==

{{Warning|The current development installation writes the postmarketOS root filesystem to the physical <code>super</code> partition. This replaces the Android system layout used by the device. Back up important data and keep a recovery path for the exact hardware variant available before flashing.}}

The current mainline port is not yet packaged as a clean upstream pmaports device. The tested installation method therefore uses matching boot and root filesystem images from the development releases.

The boot image and root filesystem are an atomic pair. The boot command line contains the filesystem UUIDs of <code>pmOS_boot</code> and <code>pmOS_root</code>, so assets from different releases must not be mixed.

=== Verify the device ===

Enter bootloader fastboot and verify the product and bootloader state:

<syntaxhighlight lang="shell-session">
$ fastboot devices
$ fastboot getvar product
$ fastboot getvar unlocked
</syntaxhighlight>

The product should report <code>hotdog</code> and the bootloader must be unlocked.

=== Verify and expand the release ===

Verify the downloaded release assets before flashing:

<syntaxhighlight lang="shell-session">
$ sha256sum -c SHA256SUMS
</syntaxhighlight>

If the root filesystem archive is split into multiple parts, reconstruct it in numeric order:

<syntaxhighlight lang="shell-session">
$ cat oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img.zst.part* \
    > oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img.zst
</syntaxhighlight>

Expand the root filesystem:

<syntaxhighlight lang="shell-session">
$ zstd -d --keep oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img.zst
</syntaxhighlight>

The expanded file is a raw GPT image containing <code>pmOS_boot</code> and <code>pmOS_root</code>. It is not an Android sparse image.

=== Flash the root filesystem ===

The root filesystem must be written to <code>super</code> from userspace fastboot (<code>fastbootd</code>).

From bootloader fastboot:

<syntaxhighlight lang="shell-session">
$ fastboot reboot fastboot
$ fastboot getvar is-userspace
</syntaxhighlight>

<code>is-userspace</code> must report <code>yes</code>.

Flash the root filesystem with bounded sparse transfers:

<syntaxhighlight lang="shell-session">
$ fastboot -S 128M flash super \
    oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-rootfs.img
</syntaxhighlight>

The bootloader fastboot implementation was not reliable for the complete <code>super</code> transfer during hardware validation, so direct bootloader flashing of <code>super</code> should not be substituted for fastbootd.

=== Flash the boot image ===

Return to bootloader fastboot and write the matching boot image to slot B:

<syntaxhighlight lang="shell-session">
$ fastboot reboot bootloader
$ fastboot flash boot_b \
    oneplus-7t-pro-hotdog-vX.Y.Z-alpha.N-boot.img
$ fastboot set_active b
$ fastboot reboot
</syntaxhighlight>

The first boot can take longer while the root filesystem is checked and expanded.

A successful boot exposes USB networking at <code>172.16.42.1</code>.

If <code>fastboot reboot fastboot</code> cannot start fastbootd, a compatible recovery is required before continuing. Do not replace the tested fastbootd procedure with a direct <code>super</code> write from bootloader fastboot.

For the exact procedure corresponding to the currently published release, see the [https://github.com/Sr-0w/hotdog-linux-bringup/blob/main/docs/release-install.md release installation guide].

== Components ==

{| class="wikitable"
! Component
! Model
! Notes
|-
| Chipset
| Qualcomm SM8150-AC
| Snapdragon 855+
|-
| GPU
| Adreno 640
| Freedreno / Turnip
|-
| Internal storage
| UFS 3.0
| 256 GB
|-
| Touchscreen
| Samsung S6SY761
|
|-
| Wi-Fi
| Qualcomm WCN3990
|
|-
| Bluetooth
| Qualcomm WCN3990
|
|-
| Audio codec
| Qualcomm WCD9340
|
|-
| Speaker amplifiers
| NXP TFA9874 ×2
| Internal stereo speakers
|-
| Main camera
| Sony IMX586
| 48 MP
|-
| Telephoto camera
| Samsung S5K3M5
|
|-
| Ultra-wide camera
| Sony IMX481
|
|-
| Front camera
| Sony IMX471
| Motorized pop-up module
|-
| Camera flash
| Qualcomm PM8150L
| Dual-channel torch/strobe
|-
| Accelerometer / gyroscope
| STMicroelectronics LSM6DSM
| Managed by SLPI/SEE
|-
| Magnetometer
| MEMSIC MMC5603x
| Managed by SLPI/SEE
|-
| Ambient light / proximity
| ams TCS3701
| Managed by SLPI/SEE
|-
| SAR sensor
| Semtech SX9324
| Managed by SLPI/SEE
|-
| Range sensor
| STMicroelectronics VL53L1
| Not yet supported
|-
| NFC
| NXP PN553
|
|-
| Vibration motor
| Awinic AW8697
|
|-
| Fuel gauge
| Texas Instruments bq27421-compatible
|
|-
| Charger
| Qualcomm SMB5
| PM8150 family
|-
| Fingerprint
| Goodix G_OPTICAL_18865_G3
| In-display optical sensor
|}

== Mainline Linux ==

The current port uses Linux 6.16 and boots directly from the stock OnePlus A/B bootloader. The downstream Android 4.14 kernel is not used during normal postmarketOS operation.

The persistent root filesystem runs from UFS. Plasma Mobile uses accelerated Adreno 640 rendering through Freedreno and Turnip.

Normal software reboot, automatic A/B success marking, bootloader selection and recovery selection are validated. The current recovery is an Android/Lineage userdebug environment with authorized root ADB; a native postmarketOS recovery and the final installer rollback flow remain incomplete.

The current development kernel still carries changes that have not all been accepted upstream; <code>status_mainline = Y</code> refers to the close-to-mainline runtime architecture rather than every device-specific change already being merged into Linus' tree.

== Display and graphics ==

The internal panel operates at its native 1440×3120 resolution through the Qualcomm DPU, DSI and DSC pipeline.

60 Hz operation is the stable reference mode. 90 Hz and runtime 60/90 Hz switching work at the functional level, but intermittent DSI FIFO/timeout events and panel reinitializations have been observed. The aggregate display status is therefore partial.

Adreno 640 acceleration works with Freedreno and Turnip. Plasma Mobile, Vulkan applications and accelerated KMS scanout have been hardware-tested.

== USB-C and DisplayPort ==

USB-C dual-role operation, USB-PD detection and USB 3 SuperSpeed are functional.

Powered host mode, unpowered host/source mode, USB mass storage and dock operation have been hardware-tested. A dock hub and RTL8153 Ethernet adapter enumerate at 5 Gbit/s.

DisplayPort video works at 2560×1440@60 while the internal display remains active.

The RTL8153 binds to <code>r8152</code> and creates <code>eth0</code>, but complete Ethernet link/data and repeatability testing remain.

CDC ACM also enumerates and exposes <code>ttyGS0</code>, but an interactive serial session has not yet been validated.

DisplayPort audio is not working. 2560×1440@120 over the tested two-lane HBR2 link exceeds the available link budget and is not supported.

== Audio ==

Both internal speakers work through the two TFA9874 amplifiers and the packaged ALSA UCM configuration.

The handset microphone is also functional.

The earpiece, remaining microphones, headset and USB-C audio detection, Bluetooth audio, call audio, echo/noise-reduction paths and DisplayPort audio remain incomplete.

== Cameras ==

All four physical cameras capture through the mainline CAMSS and libcamera stack.

{| class="wikitable"
! Camera
! Sensor
! Current status
|-
| Main
| Sony IMX586
| 4000×3000 RAW10 capture, processed 30 fps and experimental autofocus
|-
| Telephoto
| Samsung S5K3M5
| 4208×3120 RAW10 capture, userspace processing and experimental autofocus
|-
| Ultra-wide
| Sony IMX481
| 4656×3496 RAW10 capture and processed 30 fps
|-
| Front
| Sony IMX471
| Capture works with automatic pop-up extension and retraction
|}

The front-camera motor and Hall sensors are controlled as part of the camera lifecycle.

Production image quality is not yet available. Colour calibration, automatic white balance, noise reduction, sharpening, tone mapping and broader 3A tuning remain development work.

Both PM8150L flash channels register and pass electrical torch/strobe tests without reporting a fault. Visible-light calibration, stock-current calibration and synchronization with camera frames remain incomplete.

== Modem and mobile data ==

The Qualcomm MPSS remote processor boots and exposes QRTR and QMI services. RMTFS and the associated modem services are available.

ModemManager can communicate with the modem and read its identity. The SM8150 IPA path starts and creates <code>rmnet_ipa0</code>.

Operator scanning and camping without a SIM have been observed.

SIM/PIN handling, network registration with a physical SIM, LTE data, SMS, cellular calls and IMS are not yet hardware-validated.

== GNSS ==

The modem's QMI LOC service reports capabilities and accepts GNSS engine start and stop requests.

Integration with a standard Linux location service, real coordinate fixes, A-GPS, application permissions and suspend policy remain incomplete.

== Sensors ==

The handset's physical sensors are managed by Qualcomm's SLPI/SEE sensor stack rather than exposed directly as application-processor I2C/SPI devices.

The validated firmware baseline is:

<pre>
SLPI.HY.2.2-00083
</pre>

With the original OnePlus vendor sensor configuration, the following eight applicable hardware sensor types are published:

* Accelerometer
* Gyroscope
* Sensor temperature
* Motion detection
* Magnetometer
* Ambient light
* Proximity
* SAR

The sensor stack publishes 41 of 59 SEE data types. Ambient-light events have been hardware-tested with changing live values.

The later <code>SLPI.HY.2.2-00121</code> firmware boots the sensor infrastructure but does not bring up the physical sensor set correctly on the tested handset.

Vendor configuration entries named <code>rgb</code> and <code>cct</code> are not implemented as SEE data types by either tested SLPI firmware and are not counted as missing hardware support.

== NFC ==

The PN553 works in reader mode through the Linux NCI stack.

A real ISO 14443-4 target has been detected and activated, and bidirectional ISO 7816-4 APDU exchange has been hardware-tested.

Clean down/up recovery, broader tag coverage, host card emulation and secure-element integration remain incomplete.

== Haptics ==

The AW8697 is driven by the Linux force-feedback interface and physical vibration has been confirmed.

Strength calibration, repeated lifecycle testing, mobile userspace integration and suspend coverage remain incomplete.

== Suspend and power management ==

System <code>s2idle</code> suspend/resume is functional.

Thirty real suspend/resume cycles across two fresh boots completed without a modem crash or Wi-Fi loss.

Wi-Fi uses WoWLAN for suspend and resumes with the network link intact.

The SMB5 charging path supports normal USB charging. The complete Plasma Mobile image has been validated with a 900 mA USB 3 SuperSpeed SDP input limit, and dock source/sink role transitions have also been tested.

Charging termination, low-battery behaviour, JEITA/thermal policy, off-mode charging and OnePlus fast-charge modes require further validation.

== Known issues ==

* Cellular calls and SMS are not yet supported.
* SIM registration and real LTE data have not yet been hardware-validated.
* Bluetooth audio and complete Bluetooth suspend/lifecycle integration are incomplete.
* The internal display has unresolved intermittent DSI transport errors, primarily affecting the 90 Hz path.
* Touch/input resume lifecycle still requires broader validation.
* DisplayPort audio is not working.
* UFS ICE and the blk-crypto profile are operational. The current root
  filesystem is not claimed encrypted; encrypted-volume provisioning and
  ciphertext validation remain separate work.
* Camera image processing and colour calibration are not production-ready.
* Camera flash synchronization with capture frames remains incomplete.
* The earpiece, headset path and several microphone/audio routes are not yet supported.
* The three-position alert slider is not yet exposed.
* Fingerprint authentication is not supported.
* OnePlus Warp fast charging is not supported.
* Full-disk encryption has not been revalidated with the current mainline port.
* A native postmarketOS recovery image is not yet supplied. The validated
  recovery target is the existing Android/Lineage userdebug recovery.
* The current installation procedure is a manual development workflow; flashing through <code>pmbootstrap flasher</code> is not yet supported.

== Contributors ==

* [[User:Sr-0w|Sr-0w]]

== Users owning this device ==

{{Device owners}}

== Resources ==

* [https://github.com/Sr-0w/hotdog-linux-bringup Mainline Linux / postmarketOS bring-up repository]
* [https://github.com/Sr-0w/hotdog-linux-bringup/blob/main/docs/status.md Hardware support status]
* [https://github.com/Sr-0w/hotdog-linux-bringup/blob/main/docs/roadmap.md Development roadmap]
* [https://github.com/Sr-0w/hotdog-linux-bringup/blob/main/docs/release-install.md Release installation guide]
* [https://github.com/Sr-0w/hotdog-linux-bringup/blob/main/docs/upstream-submissions.md Linux upstream submissions]

== See also ==

* [[Qualcomm Snapdragon 855 (SM8150)]]
