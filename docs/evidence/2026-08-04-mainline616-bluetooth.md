# Mainline 6.16 WCN3990 Bluetooth bring-up

Date: 2026-08-04

Device: OnePlus 7T Pro HD1913 (`hotdog`)

Result: revision `r14` boots directly from the OnePlus bootloader, registers
the WCN3990 UART transport, reads the physical controller identity, loads the
packaged revision-21 firmware through a temporary filename alias, registers a
BlueZ controller, and receives advertisements from eight nearby devices.
The handset later entered Qualcomm `05c6:900e` while going to sleep. Bluetooth
is therefore validated for basic active operation, but suspend/resume is not
safe or accepted yet.

Revision `r15` selects the proven firmware names through the standard device
tree property. It passes schema and package validation and has an AVB-valid
boot image, but it has not yet been written to hardware.

## Isolated revisions

| Revision | Isolated change | Result |
|---|---|---|
| `r14` | Enable QUPv3 UART13, the WCN3990 serdev child, sleep pins, interrupt, and four supplies | Direct boot succeeded. `ttyHS1`, `hci_uart`, `btqca`, Bluetooth rfkill, and the physical controller appeared. Generic firmware-name derivation requested files that were not packaged. |
| `r14` live diagnostic | Alias the packaged revision-21 NVM and rampatch files to the requested revision-01 names, then reload only `hci_uart` | Firmware setup completed, BlueZ powered the controller, and an 18-second scan received eight devices. This was a runtime diagnosis, not the final package contract. |
| `r15` | Select `crnv21.bin` and `crbtfw21.tlv` explicitly in the WCN3990 device-tree node | Schema, strict package build, image assembly, and AVB verification pass. Hardware validation is pending. |

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
the accepted `r13` initramfs and command line. It remains a prepared candidate,
not a hardware result.

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
including a named `65" OLED` endpoint and its advertised profiles. This proves
UART communication, power rails, firmware execution, HCI registration, BlueZ
control, and RF receive operation. Pairing, connections, audio profiles, and
sustained traffic remain separate tests.

## Sleep transition

The Linux USB gadget appeared at host time 19:12:11. It disconnected at
19:15:25, and Qualcomm `05c6:900e` enumerated one second later. The handset was
going to sleep at that time. No reset was sent from crashdump mode.

This establishes a strong temporal link to idle sleep, but not yet the failing
driver or resume stage. The live `r14` diagnostic also reloaded the UART module
and performed controller setup twice, including one command timeout, so a
clean `r15` boot must be tested before assigning the crash to the Bluetooth
driver. Persistent crash data must be collected immediately after the next
manual return from `900e`.

## Next validation

1. Boot `r15` directly and capture the previous pstore record before it can be
   overwritten.
2. Inhibit automatic sleep temporarily and require direct loading of
   `qca/crbtfw21.tlv` and `qca/crnv21.bin` without runtime aliases or module
   reloads.
3. Repeat controller enumeration and scanning, then hold an awake system for
   longer than the `r14` failure interval.
4. Test one controlled suspend/resume cycle only after the clean active path
   is stable, with pstore capture prepared.

Until those checks pass, `r13` remains the accepted long-lived baseline and
`r14` is only the basic active-Bluetooth hardware result.
