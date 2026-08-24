# Runtime quick wins: ACM, haptics, flash and NFC - 2026-08-24

## USB ACM is a real, persistent console

The normal USB gadget initially exposed only `ncm.usb0`. Adding `acm.GS0`
alongside it produced `/dev/ttyGS0` on the phone and the stable host path
`/dev/serial/by-id/usb-OnePlus_OnePlus_7T_Pro_postmarketOS-if02`.

The packaged `hotdog-usb-acm` OpenRC service now maintains that composition
without replacing NCM. A host opened the serial device, received a root login
shell and exchanged a unique token in both directions. A stronger recovery
test then stopped the service, unbound the gadget, removed the ACM function,
rebound an NCM-only configuration and started the service again. The service
recreated the function and rebound the existing UDC. Afterwards:

- `/dev/ttyACM0` returned under the same by-id link;
- the ACM shell again reported `Linux hotdog 6.16.0-sm8150`;
- NCM returned at `172.16.42.1` with two of two pings received;
- no reboot, USB reset ioctl or phone-side network reconfiguration was needed.

The host-side capture is under the private run directory
`logs/watch-usb-acm-console-2026-08-24-184311`. The public package changes are
the OpenRC service, its configfs maintainer and the login helper in
`device-oneplus-hotdog`.

## Haptics pass the normal runtime path

The AW8697 `FF_RUMBLE` endpoint was exercised at 10, 25, 50, 75 and 100 percent
for 150 ms each, followed by twenty 60 ms start/stop pulses at 35 percent. All
effects completed successfully. `feedbackd` was then exercised through
`fbcli -E button-pressed -t 1 -w 2` and returned zero.

The user physically confirmed that the handset vibrated through the complete
sequence. This closes strength range, repeated start/stop and the normal
feedbackd path.

## Camera flash hardware is visible, but integration remains partial

Both `white:flash-0` and `white:flash-1` passed torch brightness 32 and a
100 mA, 100 ms hardware strobe. Both returned to brightness and strobe state
zero with no residual fault. The timeout report observed after deliberately
waiting longer than the programmed pulse cleared normally. The user confirmed
visible light from the test.

Plasma Camera still exposes no flash control on this device. The separate
flashlight integration is now fixed: one channel is named `white:torch`, so
Plasma Mobile's existing quick-setting backend discovers it. The user
confirmed that the quick-setting button is present and controls visible light.
Camera synchronization remains a separate open item.

## NFC down/up recovery

The PN553 reader was already validated with a real ISO 14443-4 activation and
APDU exchange. On this boot, three consecutive `rfkill block nfc` / `rfkill
unblock nfc` cycles each changed the software block state as requested. After
every cycle `/sys/class/nfc/nfc0` remained present, the final state was
unblocked, and the NXP NCI modules remained loaded.

This closes clean reader down/up recovery. HCE and secure-element operation are
separate product features and are not required for the Linux reader-mode
support claim.
