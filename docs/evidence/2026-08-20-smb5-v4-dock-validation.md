# Qualcomm SMB5 v4 and USB-C role validation

Date: 2026-08-20

## Status

The exact SMB5 v4 driver passed hardware validation on the OnePlus 7T Pro.
Charging remained guarded and coherent, a powered dock worked with the phone
as data host and power sink, and the same dock worked unpowered with the phone
as data host and VBUS source. Both plug orientations were tested. Returning to
the PC cable restored the NCM gadget and SSH without a reboot.

Ethernet enumeration passed, but Ethernet traffic remains blocked on a missing
physical link. The current run did not repeat visual DisplayPort confirmation.

## Candidate identity

The frozen upstream candidate is commit
`e566d5d46a0949ae322c780ca6fd407c46708c70`, tree
`60046cfaec9c935d3a19ead29ec859bf3256dd6f`. The exact candidate
`qcom_smbx.c` Git blob is
`bc2b1cd3ed6822693f8dd49d217f69a02f3d02b1`, with SHA-256
`1dbd2926ea80941e5f1a06488301ce15cd133d84323bb5616164693da2a98a74`.
The binding SHA-256 is
`7e452e76319a4d08b333e52e59a5ea2218991e8e7416e2727dabcd2bb05d8407`.

The candidate was overlaid onto Hotdog baseline commit
`c9f60c127607a8b06395c661c38287926a2729a4`, tree
`0c05457e1ffe6c482000f14e3370a5f943415d23`. The only unrelated source
change in the test build is an existing SLPI auto-boot diagnostic parameter in
`qcom_q6v5_pas.c`; it does not alter the charger, Type-C, USB or regulator
paths. Candidate blobs were hashed before and after the overlay.

## Build and flash

The full LLVM build covered `Image`, modules and DTBs. The runtime identifies
itself as:

```text
Linux 6.16.0-sm8150 #4-smb5-v4-e566d5d4 SMP PREEMPT
```

| Artifact | SHA-256 |
| --- | --- |
| `Image` | `83451554de054acf484ea00b5889c603a348263370190c0b103799470dd9271d` |
| Hotdog DTB | `c11594377d6cc98fe6b111d816e6887190d871ec08bfb8d4e24e4ed68a86d432` |
| `vmlinux` | `bae89241a1a93f0018d23e22395035db4cb62fd0b828d157ee29347ab9490d0f` |
| `qcom_smbx.o` | `b0d0f46c5121f01d2648fc9a3df5de094169410ab37c9e2d35f499a086c25e38` |
| kernel config | `abca6b0478cff39ef7c84bab5ee852c89c1cc1e500e5af7bce61d8e1644f1fdd` |
| partition-sized AVB `boot.img` | `d881abafd3496a24cd4620e5adb4f56afbf4279e6c7136ac9197af0ab726b1f6` |

AVB verification passed. The image was written once to `boot_b`; a complete
100,663,296-byte readback matched the local image. The phone booted directly
into the full postmarketOS system with 93 modules loaded, Wi-Fi connected and
USB networking available.

## Charger result

SMB5 probed without a charger-scoped warning or failure:

```text
Generation SMB5
charge limits: float=4400000 uV fast=1500000 uA input=500000 uA
```

The initial state was `online=1`, `Charging`, health `Good`, approximately
4.785 V and 478 mA with a 500 mA limit. A guarded 180-second run collected 37
samples: input voltage was 4,781,312 to 4,788,576 uV, current was 477,180 to
478,805 uA, and battery temperature was 33.7 to 34.3 C. No guard fired.

The guarded 600-second run collected 121 samples. Input voltage was 4,773,008
to 4,837,360 uV, current was 339,640 to 479,455 uA, battery voltage was
4,368,000 to 4,399,000 uV and battery temperature fell from 35.4 to 32.5 C.
The charger remained online with health `Good`; all 121 guards passed.

The local Hotdog baseline's DWC3 gadget asks the charger power supply to set
`INPUT_CURRENT_LIMIT`; the upstream-shaped SMB5 candidate intentionally has no
setter for that property and logs `No setter for property: 39`. This is a
test-baseline integration mismatch, not a failed SMB5 probe. The driver kept
its conservative 500 mA limit. The custom 900 mA complete-image experiment is
not part of this candidate or this validation.

## Powered dock: host and sink

With external power attached to the dock, both Type-C plug orientations
reported:

```text
data_role=host
power_role=sink
power_operation_mode=usb_power_delivery
usb_vbus=disabled
```

The USB 2 and USB 3 hubs, a SuperSpeed RTL8153 Ethernet adapter and a USB mass
storage device enumerated. A 64 MiB read-only storage read produced the same
SHA-256 in both orientations. The Ethernet driver bound and created `eth0`,
but traffic could not be tested because no Ethernet cable/carrier was present.
DisplayPort was reported connected; this run did not repeat the earlier visual
2560x1440 confirmation.

The charger remained online and healthy. The dock path reported a selected
USB-PD source and a higher input-current capability while the phone remained a
power sink. Voltage/current telemetry on the charger power supply reads zero
on this path, so it is not used as a charging-rate claim.

## Unpowered dock: host and source

After removing only the dock's external power, the phone remained data host
and changed to power source:

```text
data_role=host
power_role=source
usb_vbus=enabled
```

The hubs, Ethernet adapter and storage device re-enumerated and functioned in
both plug orientations. The same read-only 64 MiB storage hash was obtained in
all four dock cases. The battery power supply then supplied the system, while
the SMB5 charger correctly reported offline/discharging.

The unpowered dock could not train its DisplayPort link and timed out. That is
expected without power for this dock and is not attributed to SMB5.

## Return to USB gadget

The dock was removed and the direct PC cable reattached without rebooting the
phone. Type-C returned to data-device and power-sink roles, `usb_vbus` was
disabled, the NCM network interface returned, and ping plus SSH passed. The
charger returned to `online=1`, `Charging`, health `Good`, approximately
4.78 V and 477 mA at the 500 mA limit. The boot ID was unchanged across every
dock transition.

No charger/Type-C/VBUS test produced an oops, panic, lockdep report, UVLO,
over-current or over-voltage event. Existing unrelated framebuffer, SPMI and
device-link warnings remain in the Hotdog baseline. The RTL8153 used its
driver fallback because the optional `rtl8153b-2.fw` file is not installed.

## Verdicts

| Gate | Verdict |
| --- | --- |
| Exact candidate identity and full build | PASS |
| Boot, SMB5 probe and power-supply properties | PASS |
| Guarded 180-second charging run | PASS |
| Guarded 600-second charging run | PASS |
| Powered dock, host plus sink, both orientations | PASS |
| Unpowered dock, host plus source VBUS, both orientations | PASS |
| USB storage read in all dock cases | PASS |
| Ethernet enumeration and driver binding | PASS |
| Ethernet traffic | BLOCKED: no physical carrier |
| Visual DisplayPort output in this run | BLOCKED: not repeated |
| Return to NCM gadget and SSH without reboot | PASS |

## Evidence paths

Private build and runtime evidence is stored under
`logs/2026-08-20-smb5-v4-e566d5d4/`. The important files are:

- `03-source-and-overlay-proof.txt`, `14-rebuild-release-match.log` and
  `16-flash-r2-readback.txt`;
- `17-reboot-r2-monitor.txt`, `18-r2-var-log-dmesg.txt` and
  `19-r2-initial-state.txt`;
- `21-charge-trace-180s.csv` and `38-charge-trace-600s.csv`;
- `27-powered-dock-final-state.txt`,
  `28-powered-dock-flipped-orientation.txt` and
  `30-powered-dock-flipped-storage-read.txt`;
- `32-unpowered-dock-state-live.txt`, `33-unpowered-dock-functional.txt`,
  `34-unpowered-dock-flipped-functional.txt` and
  `35-unpowered-dock-flipped-dmesg.txt`;
- `36-return-direct-pc-gadget.txt` and `37-return-direct-pc-dmesg.txt`.
- `39-final-dmesg.txt` for the post-test kernel audit.
