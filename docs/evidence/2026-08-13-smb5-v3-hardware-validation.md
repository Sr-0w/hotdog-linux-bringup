# Qualcomm SMB5 v3 hardware validation

Date: 2026-08-13

## Status

Validation passed. The exact v3 charger implementation builds and boots on the
OnePlus 7T Pro. The 180-second and 600-second guarded charge runs, a host-side
USB deauthorization/re-authorization cycle, and a physical VBUS cable cycle
all passed. No SMB5-scoped warning, error, oops or lockdep report occurred.

## Candidate identity

The frozen upstream candidate is commit
`ba9890604be1a25fe77121c9fe2665535d91ee3f`, tree
`face07e87b8b06d4d93e0d8d598e13a64d72f255`. The build overlay uses the exact
candidate blobs for:

- `drivers/power/supply/qcom_smbx.c`;
- `drivers/power/supply/Kconfig`;
- `Documentation/devicetree/bindings/power/supply/qcom,pmi8998-charger.yaml`.

The candidate driver SHA-256 and build-overlay SHA-256 are both
`e435cb7652433756adb1b13fc535c6566109c79d437fdb29c66142db6e95204c`.

The test kernel is a backport onto the hardware-validated Hotdog 6.16 tree.
Because v3 uses the power-supply registration init callback added after 6.16,
the build also carries upstream prerequisite
`c1eb5905fdce35a66173658a93819641e5220c18` (`power: supply: Add registration
init callback`). The SMB5 candidate source itself is unchanged.

## Build and artifact

The full LLVM build completed for `Image`, modules and DTBs. The resulting
kernel identifies itself as:

```text
Linux version 6.16.0-sm8150 (postmarketOS@pmaports) (clang version 22.1.8, LLD 22.1.8) #177-smb5-v3-ba989060 SMP PREEMPT 2025-08-22 17:25:08
```

The kernel release and module vermagic both remain `6.16.0-sm8150`, preserving
compatibility with the installed postmarketOS modules.

| Artifact | SHA-256 |
| --- | --- |
| `Image` | `a6a5bf4c995eea3f8ae410d9c8215017806d1334109afbb22692d6ed641a9124` |
| Hotdog DTB | `3647b457cd0f83d5806222aaa3042940bd5d7507cbce4796742a8afeeac4b819` |
| `vmlinux` | `36449f4548a30609e0d938d3df2b1fe672ddbf77ce7aff42d47f344799ba5132` |
| partition-sized AVB `boot.img` | `7ac65591ecda2adf00efb3a35134ef6872a0cf044c73698a1b6785532ecf6e6d` |

The image was written once to `boot_b` and read back over the complete
100,663,296-byte partition. The readback hash matched the local image.

## Boot result

The phone booted directly into postmarketOS with a new boot ID and the exact
`#177-smb5-v3-ba989060` build marker. The charger probe reported:

```text
qcom-smbx-charger c440000.spmi:pmic@2:charger@1000: Generation SMB5
qcom-smbx-charger c440000.spmi:pmic@2:charger@1000: charge limits: float=4400000 uV fast=1500000 uA input=500000 uA
```

No warning, error, oops or lockdep report was associated with `qcom_smbx` or
the SMB5 probe. The complete boot log contains pre-existing warnings from
unrelated framebuffer/IPA bring-up code.

Initial power-supply state was coherent:

```text
pm8150b-charger online=1 status=Charging health=Good
voltage_now=4785456 current_now=479130 current_max=500000
```

The fuel gauge reported a negative battery current while the charger reported
charging because the running system consumed more than the deliberately
conservative 500 mA USB input limit.

## Guarded charge runs

The 180-second run collected 19 samples:

- input voltage: 4,780,272 to 4,785,456 uV;
- input current: 477,505 to 478,805 uA;
- battery temperature: 37.5 to 37.6 C;
- health remained `Good` and the 500,000 uA limit was never exceeded.

The 600-second run collected 21 samples with active abort guards:

- input voltage: 4,777,152 to 4,785,456 uV;
- input current: 476,855 to 479,130 uA;
- battery temperature: 37.2 to 37.4 C;
- no guard fired and health remained `Good` throughout.

## USB gadget reconnect

The host deauthorized only the OnePlus USB device for ten seconds, then
reauthorized it. The host kernel recorded the CDC NCM interface unregistering
at 12:29:13 and registering again at 12:29:24. USB networking, ping and SSH all
recovered without rebooting the phone. The charger remained coherent after
the cycle:

```text
pm8150b-charger online=1 status=Charging health=Good
voltage_now=4779232 current_now=477830 current_max=500000
```

This validates USB gadget teardown and reprobe, but it is not evidence for a
charger detach/attach notification: the host-side authorization switch leaves
VBUS asserted, so `online=1` was expected throughout.

## Physical VBUS cycle

The USB-C cable was physically disconnected for approximately 14 seconds. The
host recorded the device and CDC NCM interface disappearing at 12:36:26 and a
fresh SuperSpeed enumeration at 12:36:40. This was a real cable cycle, not the
host authorization mechanism described above.

The phone remained on the same boot and its Type-C controller recorded two
`tx_sig` interrupts at boot times 1568 and 1569 seconds, coincident with the
reconnection. USB networking and SSH recovered automatically. The first state
read after reconnect was:

```text
pm8150b-charger online=1 status=Charging health=Good
voltage_now=4779232 current_now=477505 current_max=500000
```

Seven samples over the following 60 seconds all remained `online=1`,
`Charging` and `Good`. Input voltage stayed between 4,777,152 and 4,780,272 uV,
input current between 476,855 and 478,805 uA, and battery temperature between
36.8 and 36.9 C. A final complete-dmesg audit found no SMB5-scoped fatal
match.

## Evidence paths

Build and runtime evidence is under
`logs/2026-08-13-smb5-v3-ba989060/`. The most relevant files are:

- `06-source-proof.txt` and `13-prereq-proof.txt`;
- `14-full-build-resume.log` and `17-full-build-localversion.log`;
- `18-final-build-proof.txt` and `19-bootimg-build.log`;
- `24-flash-boot-b.log` and `25-reboot-monitor.log`;
- `26-boot-dmesg-complete.txt` and `28-smb5-boot-audit.txt`;
- `29-charge-180s.txt`, `30-charge-600s.txt` and
  `32-charge-600s-summary.txt`;
- `33-post-charge-dmesg-complete.txt` and
  `34-post-charge-smb5-audit.txt`;
- `35-host-usb-deauthorize-cycle.txt`, `36-post-host-usb-cycle.txt` and
  `37-host-usb-kernel-events.txt`;
- `38-physical-vbus-host-events.txt`, `39-physical-vbus-post-reconnect.txt`,
  `40-physical-vbus-post-reconnect-60s.txt`,
  `41-physical-vbus-final-dmesg.txt` and
  `42-physical-vbus-smb5-audit.txt`.

## Optional test not performed

- Suspend/resume was optional for this gate and is not currently practical:
  the development image deliberately disables sleep because this hardware
  port cannot yet guarantee remote wake or preserve USB networking while
  suspended.
