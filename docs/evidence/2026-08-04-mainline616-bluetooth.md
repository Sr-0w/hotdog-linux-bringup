# Mainline 6.16 WCN3990 Bluetooth bring-up

Date: 2026-08-04

Device: OnePlus 7T Pro HD1913 (`hotdog`)

Result: revision `r15` boots directly from the OnePlus bootloader, selects the
packaged revision-21 firmware through the standard device-tree property,
registers a BlueZ controller, scans, and sustains real Bluetooth HID
connections. Wi-Fi remains associated and passes local-gateway plus external
IPv4 reachability tests at the same time.

One `r15` run entered Qualcomm `05c6:900e` abruptly at 275 seconds of uptime,
without a kernel panic or suspend entry in ramoops. The failure did not repeat
in a clean isolation boot: the same image completed 600 seconds with Bluetooth
blocked, then another 600 seconds with the controller enabled, scanning, and a
Bluetooth game controller connected. Basic active Bluetooth is therefore
hardware-validated. System suspend/resume and the cause of the isolated
crashdump transition remain open.

## Isolated revisions

| Revision | Isolated change | Result |
|---|---|---|
| `r14` | Enable QUPv3 UART13, the WCN3990 serdev child, sleep pins, interrupt, and four supplies | Direct boot succeeded. `ttyHS1`, `hci_uart`, `btqca`, Bluetooth rfkill, and the physical controller appeared. Generic firmware-name derivation requested files that were not packaged. |
| `r14` live diagnostic | Alias the packaged revision-21 NVM and rampatch files to the requested revision-01 names, then reload only `hci_uart` | Firmware setup completed, BlueZ powered the controller, and an 18-second scan received eight devices. This was a runtime diagnosis, not the final package contract. |
| `r15` | Select `crnv21.bin` and `crbtfw21.tlv` explicitly in the WCN3990 device-tree node | Direct boot, native firmware loading, scan, and HID connections succeed. One run entered `900e`; two subsequent 600-second isolation windows completed without a USB transition. |

The UART13 description follows the SM8150 serial engine at `0xc8c000`. Its
sleep state covers GPIOs 43 through 46, and the controller uses the PM8150 and
PM8150L rails identified by the stock HD1913 overlay and existing SM8150
WCN3990 bindings. Both `hci_uart.ko` and `btqca.ko` are enforced by the package
validator.

## Build and image identity

Both revisions were strict pmbootstrap builds. The source-built DTB also
passes the official device-tree schema checks.

| Revision | Kernel APK SHA256 | Kernel SHA256 | DTB SHA256 | Boot image SHA256 |
|---|---|---|---|---|
| `r14` | `2af1fbddc330910c014574a386bcf62ee9082b07ff339c3b73eafe9b140e749f` | `445d6f58ead9b80bc5abbe9e40c34636b2832b082cdc4ab8dc2983e5950d4c73` | `be436a9a56e1fc1e875fc45f94331b83d119c44904144779536d5653eb6fb31b` | `623aa5193a535a98965a59738d4256ead84ceab7188a92263880a5e78bce11ee` |
| `r15` | `ca030a9fdbbf8fdd580f50b421a83713b2038ca3ed8651332771b79176aab76e` | `be4728aa5d860c4c2eeb203e99d28ddaa89e1c58367d19bafabe9d7368a8a408` | `512f71ef5bd70198cbe45ce6a9738370e8e43d294d2b3b3e9d33e54c54be3bf0` | `f003985db63b6f60d1bf311b313882568c9279c3a32ce6ad76902115bc51a8c4` |

The `r14` APK is 25,537,004 bytes. Its 96 MiB boot image was written to
`boot_b` from the running `r13` system and read back completely before reboot.
The flash record is retained under
`logs/flash-boot-b-from-pmos-ssh-2026-08-04-191129`.

The `r15` APK is 25,537,039 bytes. Its 96 MiB boot image is AVB-valid and keeps
the accepted `r13` initramfs and command line. The image was written to
`boot_b`, read back with the same SHA256, and then hardware-validated as kernel
build `#16-oneplus-hotdog-mainline616`.

## Direct-boot result

Revision `r14` boot ID `15943885-4bda-41f0-8754-2fdb21559b56` reported:

```text
Linux hotdog 6.16.0-sm8150 #15-oneplus-hotdog-mainline616
```

USB networking, SSH, storage, the read-write postmarketOS root, display,
touch, GPU, Plasma Mobile, MPSS, and Wi-Fi all returned. UART13 registered as
`ttyHS1` at `0xc8c000`, and the kernel initialized the WCN3990 transport.

The physical controller reported:

```text
QCA Product ID   : 0x0000000a
QCA SOC Version  : 0x40010224
QCA ROM Version  : 0x00001001
QCA Patch Version: 0x00006699
QCA controller version 0x02241001
```

The generic QCA filename derivation selected `qca/crbtfw01.tlv`, which is not
part of the Hotdog firmware package. The package provides revision-21 files.
After temporary aliases mapped `crbtfw01.tlv` to `crbtfw21.tlv` and
`crnv01.bin` to `crnv21.bin`, the same controller completed setup:

```text
Bluetooth: hci0: QCA Downloading qca/crbtfw01.tlv
Bluetooth: hci0: QCA Downloading qca/crnv01.bin
Bluetooth: hci0: QCA setup on UART is completed
```

BlueZ then exposed the controller as powered and pairable, with central and
peripheral roles. A real 18-second scan received eight devices,
including a nearby media endpoint and its advertised profiles. This proves UART
communication, power rails, firmware execution, HCI registration, BlueZ
control, and RF receive operation. Pairing, connections, audio profiles, and
sustained traffic remain separate tests for this `r14` run.

Revision `r15` removes the diagnostic aliases. A direct boot requested and
loaded the packaged files by their real names:

```text
Bluetooth: hci0: QCA Downloading qca/crbtfw21.tlv
Bluetooth: hci0: QCA Downloading qca/crnv21.bin
Bluetooth: hci0: QCA setup on UART is completed
```

BlueZ powered the controller, a scan received twelve devices, and a previously
paired Bluetooth HID keyboard connected and registered an input device. A
later clean boot also connected a Bluetooth game controller and kept it active
through the end of a 600-second observation. These results validate controller
firmware, receive scanning, pairing state, L2CAP/HID traffic, and userspace HID
delivery. Audio profiles and throughput remain untested.

## Crashdump observations

The `r14` diagnostic run disconnected from USB and enumerated as Qualcomm
`05c6:900e` after roughly three minutes. That run had reloaded `hci_uart`,
performed controller setup twice, and recorded one command timeout, so it was
not a clean power-management baseline.

The first clean `r15` boot also entered `900e`, at roughly 275 seconds of
uptime. An `elogind-inhibit` block for both idle and sleep was active, so this
was not a normal system-suspend transition. The bounded read-only ramoops
capture contains no panic, oops, call trace, or suspend entry. Its last pmsg
heartbeats show the root filesystem, UFS block device, USB gadget, and charger
still present; UFS runtime PM was suspended for the final 20 seconds. Wi-Fi was
associated and a Bluetooth HID keyboard had connected earlier in the run.

UFS runtime suspend alone is ruled out as a sufficient trigger by the next
boot. With Bluetooth soft-blocked and BlueZ stopped, 121 five-second samples
completed from 117.12 through 720.97 seconds of uptime. UFS was runtime
suspended for most of that interval while root storage, USB, SSH, and charging
remained available.

Bluetooth was then enabled on the same boot with no paired device initially.
The controller entered Qualcomm in-band sleep with both clock votes off. A
Bluetooth game controller later reconnected spontaneously and produced real
wake/sleep traffic; a subsequent scan added discovery traffic. The complete
121-sample window ran from 853.40 through 1457.24 seconds with no USB
transition. IBS counters ended in the asleep state with both clock votes off.
This does not explain the first `r15` crash, but it shows that controller idle,
scanning, and a sustained HID connection are not independently sufficient to
reproduce it. Powering off the connected game controller then produced another
61-sample, 300-second window with no USB transition; the connection count
stayed at zero and every IBS counter remained unchanged. A normal HID
disconnect is therefore not sufficient either.

## Next validation

1. Repeat the original keyboard connection while recording integrated IBS
   counters and pmsg heartbeats.
2. If the crash reproduces, separate display blanking from the Bluetooth
   connection while keeping the system-sleep inhibitor active.
3. Validate repeated cold boots, discovery, pairing, disconnect, reconnect,
   and longer bidirectional HID traffic.
4. Test one controlled suspend/resume cycle only after the active path is
   repeatably stable, with automatic read-only ramoops capture armed.

Revision `r15` is the current active-Bluetooth candidate. Revision `r13`
remains the conservative long-lived fallback until the isolated `900e`
transition is understood or disproved through repeated stability runs.
