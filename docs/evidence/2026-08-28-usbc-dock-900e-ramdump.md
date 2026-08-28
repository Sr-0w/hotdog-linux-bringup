# USB-C dock insertion entered Qualcomm 900e after hub enumeration

Date: 2026-08-28

## Trigger and capture

The phone was running the hardware-tested 6.17 r30 kernel after the Bluetooth
RX-DMA fix. Inserting the USB-C dock froze the phone and exposed Qualcomm USB
ID `05c6:900e`. SSH, USB networking and fastboot were no longer reachable.
This was 900e diagnostic mode, not 9008 EDL.

The host did not reset, reboot or send a normal protocol command to the phone.
The existing pinned QDL build captured the diagnostic table with:

```text
qdl ramdump --skip-reset
```

The capture completed in place and left the phone in 900e. It contains 48
regions, including four 2 GiB DDR segments, the firmware KMSG region, OCIMEM,
PIMEM, DCC, IPA, PMIC reset state and the complete ramoops reservation. A
private SHA-256 manifest covers every region. Raw RAM and decoded private
runtime data are not part of the repository.

## Kernel identity

The persistent console and the in-memory printk ring agree on the exact
kernel:

```text
Linux 6.17.0-sm8150-hotdog-clean
#31-oneplus-hotdog-mainline617-clean
Alpine clang 22.1.8, LLD 22.1.8
```

The r30 DTB SHA-256 is
`f37041a18cab68f5a11afc495765d2c0f8a7d084983b3412cdc38cd91fa2c3f7`.
It includes the DisplayPort altmode, DP audio link, DP jack-presence callback,
absolute ramoops reservation and the GENI zero-length RX-DMA fix.

An exact-symbol `vmlinux` was reconstructed from commit `c71f52e`, the 30
patches, the config extracted from the dump, and the same Alpine compiler
identity. Qualcomm ramparser needed three local analysis-only compatibility
adjustments:

- separate physical load offset `0x80000` from virtual KASLR offset
  `0x2b49c0080000`;
- invalidate symbol addresses cached before GDB received the KASLR offset;
- use the SM8150 runtime VA48 fallback rather than the configured VA52 maximum.

These changes were made only in a private parser copy. They are not kernel or
project changes.

## Last kernel events

The in-memory printk ring contains no panic, oops, lockup report or Linux
watchdog backtrace. The final sequence is:

```text
[2052.350465] dwc3 a600000.usb: remote wakeup not configured
[2059.914605] dwc3 a600000.usb: request ... was not queued to ep3in
[2060.020990] xhci-hcd xhci-hcd.5.auto: xHCI Host Controller
[2061.092998] usb 2-1: idVendor=05e3, idProduct=0626, USB3.1 Hub
[2061.112849] hub 2-1:1.0: 4 ports detected
[2061.340947] usb 1-1: idVendor=05e3, idProduct=0610, USB2.1 Hub
[2061.399580] hub 1-1:1.0: 4 ports detected
```

The log ends immediately after the two GenesysLogic hubs. No child device,
DisplayPort HPD, DRM connector, DP audio stream or AFE start is reported.
`CheckForPanic` found no panic signature.

The Qualcomm parser reports that an FIQ cookie exists in IMEM, but the same
result appears in earlier 900e captures entered deliberately. The PMIC reset,
FSM and PON-history regions are also byte-identical to a deliberate software
900e capture. Neither item identifies the initiating fault.

## Comparison with the 6.16 oracle

The same dock repeatedly completed the next stages on the previous 6.16
kernel:

```text
USB3 hub -> Realtek 0bda:8153 -> r8152 eth0
USB2 hub -> attached USB storage
unplug -> both buses deregistered
replug -> the complete sequence repeated
```

The 6.17 tree retains the established board contracts: dual-role Type-C,
PM8150B VBUS, `usb-psy-name = "pm8150b-charger"`, SuperSpeed, FSA4480,
DisplayPort altmode, the USB3 900 mA charger selection and the 900 mA gadget
limit. The DWC3 core, host, DRD and Qualcomm glue and USB hub source are
otherwise identical to the working 6.16 oracle. The remaining boundary is a
6.17-era host/Type-C/DP transition or a recently added hotplug consumer, not a
missing VBUS or role-switch description.

## Next isolation

The first controlled candidate should remove only the new DisplayPort
jack-presence callback while retaining the DP link, DP audio ordering fixes,
USB contracts, Bluetooth fix and ramoops. The callback is the only recent
consumer that runs on DP presence and was not present in the repeatedly
working 6.16 image. A successful dock enumeration would implicate that
callback; another 900e would move the bisect below ASoC into Type-C/QMP/xHCI.

No claim is made that DisplayPort audio or dock stability works on r30.
