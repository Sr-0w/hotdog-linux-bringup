# Mainline 6.16 WCN3990 and MPSS bring-up

Date: 2026-08-04

Device: OnePlus 7T Pro HD1913 (`hotdog`)

Result: revision `r13` direct-boots from the OnePlus bootloader, starts the
modem remote processor with the device-specific RMTFS reservation, binds the
WCN3990 through `ath10k_snoc`, exposes `wlan0`, and scans both 2.4 GHz and
5 GHz networks. USB networking, SSH, storage, display, touch, GPU, and the
existing Plasma Mobile userspace remain available.

## Staged isolation

The radio path was enabled in five bounded revisions so failures in the modem
dependency could be separated from failures in the Wi-Fi consumer:

| Revision | Isolated change | Hardware result |
|---|---|---|
| `r9` | Enable WCN3990 and four regulators | The platform node bound, but MPSS remained disabled and no usable WLAN interface appeared. |
| `r10` | Add the fifth regulator and enable MPSS | The normal rootfs and SSH returned, but SCM rejected the inherited generic RMTFS reservation and the modem did not start. |
| `r11` | Move RMTFS to the OnePlus-common `0xf2901000` address | The candidate did not return USB or the rootfs. Recovery left no pstore record. |
| `r12` | Restore Hotdog's explicit `0xfc201000` RMTFS reservation and keep Wi-Fi disabled | The complete system returned; MPSS reached `running`, `rmtfs` and `tqftpserv` stayed active, and the modem firmware completed startup. |
| `r13` | Change only the already-described Wi-Fi node from disabled to okay | The complete system returned, WCN3990 firmware initialized, `wlan0` appeared, and an active scan found networks on both bands. |

The successful RMTFS layout is a 2 MiB no-map reservation at
`0xfc201000`, with client ID 1 and VMID 15. This is the address used by the
original Hotdog device tree; neither the generic SM8150 address nor the later
OnePlus-common address was interchangeable on this handset.

## Package and image evidence

All five revisions were strict pmbootstrap package builds. Each boot image is
96 MiB, AVB-verifies, and uses the same accepted initramfs and command line.

| Revision | Kernel APK SHA256 | Boot image SHA256 |
|---|---|---|
| `r9` | `664763a6f0136090687e2319403c8a2e6f2247bb3450cb35a4a4d14ae8bc9ba4` | `06ba6187f9991747c7ae12b8363d21c62a97fecc6064f0c70a359a5bbfb13b22` |
| `r10` | `90fb3e7a3159c15dc3f65b454447eb2d220be46be910f3389c16b7ae81ea9669` | `343e0b7b2a172429672c85f10696c833b7d4fee5f32cedf81ba03f65dd8ddc38` |
| `r11` | `f433198ea1f93a67a8f25bbb4c982a48026302e26158b8e37f388311520b64f8` | `bbeb1ec9eea1a02252a977a5197562fe3f1d5fd93b48aab3153acd27357f8e85` |
| `r12` | `fb12605a4e0b7e32a5177ecfd8ad24282acfd32bfbc4ae72ba6a375135873f51` | `92b8d7aee095fe1720bd89d12f0d607330b6599369f1aa8b65b9f8e068fcbb17` |
| `r13` | `cc4f75b66974e51ec9c34e108f7adebe305c9194d581179fad1d976c7bd04b55` | `28bdfd685312cd3b9aca3855d039654bd45582582c31893a031847a6ec21e557` |

The accepted `r13` package is 25,536,878 bytes. Its exact payloads are:

| Output | Size | SHA256 |
|---|---:|---|
| `boot/vmlinuz` | 27,572,232 bytes | `d0f06220b8b0cc8910fed56bf3efa55c2ecc1cf3a0a5a9357e2faf2957fa3ce6` |
| `boot/dtbs/qcom/sm8150-oneplus-hotdog.dtb` | 139,848 bytes | `bd4323a5cea4e2df4f6c4b4aa5089bee97f8be77e8fec9b2d8cfa5c92f816189` |

The `r13` image was written to `boot_b` from the running `r12` system. The
complete partition readback matched the image SHA256 before reboot.

## Hardware result

Revision `r12` boot ID `9ecaf9a3-357e-470e-b03d-a48375cc8c01`
reported kernel build `#13-oneplus-hotdog-mainline616`. The modem became
available at 6.317 seconds, loaded
`qcom/sm8150/oneplus/hotdog/modem.mbn`, and reached `running` at 8.406
seconds. `/dev/qcom_rmtfs_mem1`, `rmtfs`, `tqftpserv`, `qrtr_smd`, and
`qcom_pd_mapper` were present without an SCM assignment failure.

Revision `r13` boot ID `81adc4ee-8008-48c1-8fc7-4c18eb26b6d5`
reported kernel build `#14-oneplus-hotdog-mainline616`; USB SSH returned at
9.95 seconds. MPSS again reached `running`. WCN3990 then reported its QMI
firmware identity at 10.509 seconds and completed `ath10k_snoc` initialization
at 13.882 seconds. NetworkManager exposed `wlan0` through `ath10k_snoc`, with
both hardware and software rfkill unblocked.

A root-authorized NetworkManager rescan returned ten access points across
2.4 GHz and 5 GHz. Reported link capabilities included 195 Mbit/s on 2.4 GHz
and 1170 Mbit/s on 5 GHz. This validates firmware loading, control-plane QMI,
the MAC80211 interface, RF operation, and scan reception. Association and
sustained traffic remain separate tests.

The later direct-booted `r15` system associated through NetworkManager while
Bluetooth was active. Three ICMP requests to the local gateway and three to an
external IPv4 endpoint all returned without loss. Network identifiers,
addresses, and the randomized interface MAC are intentionally omitted from
the public evidence. This validates basic association, DHCP, routing, and
concurrent Wi-Fi/Bluetooth operation; sustained throughput is still open.

The live Plasma image initially contained `polkit-noelogind-libs`, so PolicyKit
treated the local graphical session as inactive and rejected NetworkManager
changes. Replacing it with `polkit-elogind` made the existing plugdev policy
authorize the active `plasmashell` process for connection changes, network
control, and Wi-Fi scans. The device package now carries that dependency for
future Plasma Mobile images.

## Remaining radio work

The firmware does not provide a valid factory MAC address through the current
path, so `ath10k` selects a random address at boot. That must be replaced with
a stable device address before submission. Throughput, power management,
suspend/resume, and repeated cold boots also remain open.

MPSS startup is now a validated dependency for Wi-Fi, not a telephony result.
ModemManager still exposes no WWAN device, and calls, SMS, mobile data, GNSS,
SIM handling, and emergency-call behavior are untested. Bluetooth has not yet
registered an HCI device in this `r13` result. The later Bluetooth bring-up is
documented separately in
[the revision r14/r15 evidence](2026-08-04-mainline616-bluetooth.md).
