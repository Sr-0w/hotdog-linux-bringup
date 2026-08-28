# Bluetooth disconnects exposed a zero-length GENI RX DMA stall

Date: 2026-08-28

## Trigger

The public Alpha 2 rootfs still contained kernel package r10. That package was
built before the Hotdog `hsuart0` alias, so the shipped boot image logged
`Invalid line -19`, created no `ttyHS0` and exposed no Bluetooth controller.
The current clean 6.17 branch already contained the alias and the two bounded
`hci_qca` lifecycle fixes, but had not been packaged into Alpha 2.

Kernel package r27 was installed as a controlled runtime candidate. Its DTB
exposed `hsuart0`, `ttyHS0`, `serial0-0` and `hci0`; QCA firmware setup
completed and the host computer paired with the phone. The first service
disconnect did not take down Linux, USB or SSH, which proves the lifecycle
guards prevent the earlier whole-phone failure.

The controller itself still failed. The timeline was deterministic:

```text
serial engine reports 0 RX bytes in!
Bluetooth: hci0: Opcode 0x0c1a failed: -110
Bluetooth: hci0: command 0x0c1a tx timeout
Bluetooth: hci0: crash the soc to collect controller dump
Bluetooth: hci0: Reading QCA version information failed (-110)
```

Opcode `0x0c1a` is Write Scan Enable. BlueZ then reported the controller as
unpowered even though Bluetooth rfkill and the service remained enabled. A
bounded `hci_uart` unload/reload recovered the controller without changing the
boot ID.

## Root cause

The 6.17 GENI UART RX DMA handler did this in
`qcom_geni_serial_handle_rx_dma()`:

1. unmap the RX DMA buffer and clear `port->rx_dma_addr`;
2. read `SE_DMA_RX_LEN_IN`;
3. return immediately when that register is zero;
4. rearm DMA only on the nonzero path.

A stale RX interrupt on an idle line can legitimately report zero bytes. Once
that happened, every later RX interrupt hit the empty-address guard and no HCI
response could reach BlueZ. Commands continued to transmit until their timeout
path deliberately crashed the Bluetooth SoC.

This is the upstream bug fixed by Linux commit
[`b93062b6d8a1`](https://github.com/torvalds/linux/commit/b93062b6d8a1b2d9bad235cac25558a909819026),
`serial: qcom_geni: Fix RX DMA stall when SE_DMA_RX_LEN_IN is zero`. The fix is
marked for stable and keeps zero-length completions on the normal DMA rearm
path. The project carries that upstream patch unchanged.

## r30 validation

The strict r30 package build passed with the current clean 6.17 series,
including the already-prepared DisplayPort-presence and ramoops diagnostics.
The hardware candidate used a matching r30 kernel, modules, DTB and initramfs.

| Artifact | SHA-256 |
|---|---|
| Kernel APK | `9de6ee4d3f91f45561ed6d1d45dcb131719e39c9faed349fa581bd7e3939093c` |
| Boot image | `b179842ec1052bc7dde485b09b57c16a16387ddc0359aeddc6b24572c88863e2` |
| Kernel Image | `da2060d4aba393273bb6bbc17a720ddf90695fbac8453df9cf1198ae94e24f40` |
| Hotdog DTB | `f37041a18cab68f5a11afc495765d2c0f8a7d084983b3412cdc38cd91fa2c3f7` |

The host and phone were paired from scratch repeatedly. The result covered:

- six successful complete pairings, including service resolution and normal
  disconnect;
- five remove, rediscover, re-pair and disconnect cycles;
- 20 immediate scan-enable on/off cycles, 40 HCI state changes;
- a further 31-sample, 300-second post-disconnect soak, another 62 HCI state
  changes;
- one unchanged boot ID, continuous USB networking and SSH;
- `hci0` still `UP RUNNING`, with RX increasing from 90,716 to 101,805 bytes;
- zero `0x0c1a` timeout, controller dump, hardware-error injection, QCA version
  read failure or GENI zero-RX warning.

The failed r27 run and the passing r30 run used the same hardware, firmware,
userspace peer and pairing procedure. The upstream GENI RX DMA fix closes the
observed disconnect failure.

## Reproducible follow-up

The first two r30 builds differed only in the generated built-in cpio metadata:
BusyBox `date` in the Alpine buildroot rejected the human
`KBUILD_BUILD_TIMESTAMP`, so `gen_initramfs.sh` silently used the wall-clock
time for three default entries. Their 12 mtime bytes and the derived 20-byte
kernel hash were the only Image differences; the DTB and every module were
identical.

r31 passes the same fixed epoch as `@1761609785`, a form BusyBox accepts. Two
fresh strict builds are byte-identical:

| Artifact | SHA-256 |
|---|---|
| r31 kernel APK | `618d6c7a26294e597b098cf9bc549f44794852dca07e672df4a6d8abd0e8e01e` |
| r31 kernel Image | `e9a0c2760251634fd8057ca7e340974bf27b54d8c7a35d88d45ff1a572ab1670` |

r30 remains the exact hardware-tested artifact. r31 changes only deterministic
build metadata around the same source, configuration, DTB and modules; it is
the reproducible package for subsequent image composition.

## Remaining scope

This validates BR/EDR pairing, service discovery, ordinary disconnects,
controller recovery on the failing kernel, and repeated post-fix HCI commands.
It does not by itself complete A2DP/HFP audio, BLE application behaviour,
coexistence throughput or suspend/resume with an active link.
