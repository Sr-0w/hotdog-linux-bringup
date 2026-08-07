# Mainline 6.16 MPSS and RMTFS preflight

Date: 2026-08-04

Device target: OnePlus 7T Pro (`hotdog`), tested-model baseline HD1913

Kernel target: `6.16.0-sm8150`

Result: reproducible `r11` MPSS/RMTFS candidate built and statically
validated; hardware validation is pending. This record does not claim a
working modem, QRTR service, mobile network, or Wi-Fi interface.

## Scope

Revision `r11` prepares the smallest remote-processor step needed before
WCN3990 Wi-Fi or modem userspace can be tested:

- enable the SM8150 MPSS remote processor with the packaged hotdog
  `modem.mbn` firmware;
- restore the 2 MiB Qualcomm RMTFS shared-memory region at `0xf2901000`;
- install and start the normal OpenRC `rmtfs` service in read-only mode;
- retain QRTR and QRTR-SMD module support; and
- deliberately keep the WCN3990 node disabled.

The accepted runtime baseline remains `r6`. The battery/charger `r10`
candidate must complete its separate hardware gate before `r11` is written to
the phone, so a power-driver result cannot be confused with MPSS behavior.

## RMTFS address

An earlier temporary device tree placed RMTFS at `0x89b00000`, where the
kernel reported a failed Qualcomm memory assignment. The high address used by
`r11` follows the historical OnePlus SM8150 mainline work:

- commit `8f1e0983ffe8` records that downstream allocates the same
  `0xf2901000` address on every boot; and
- commit `6e73336287b3` describes the exact `qcom,rmtfs-mem` node, 2 MiB size,
  client ID 1, and VMID 15 expected by the modem firmware.

The source-built DTB is rejected unless it contains all of the following:

| Property | Required value |
|---|---|
| Node | `/reserved-memory/memory@f2901000` |
| `compatible` | `qcom,rmtfs-mem` |
| `reg` | `<0x0 0xf2901000 0x0 0x200000>` |
| `qcom,client-id` | `<1>` |
| `qcom,vmid` | `<15>` |
| MPSS firmware | `qcom/sm8150/oneplus/hotdog/modem.mbn` |
| WCN3990 status | `disabled` |

## Userspace write protection

The `device-oneplus-hotdog-nonfree-firmware` subpackage now depends on
`rmtfs-openrc` and adds `rmtfs` to the OpenRC boot runlevel. The packaged
service defaults to `rmtfs_avoid_writing="true"`, which produces the arguments
`-s -P -r`: synchronize MPSS startup, read the device partitions, and refuse
storage writes.

The hardware collector fails the MPSS gate unless it finds the RMTFS character
device, a running `rmtfs` process with `-r`, the expected platform-memory
device, an MPSS remote processor, and the MPSS state `running`.

## Reproducible artifacts

One strict kernel build used the normal cache and a second strict build used
`pmbootstrap --no-ccache`. The APKs and their complete extracted trees are
byte-for-byte identical. Two independent boot-image assemblies also produced
identical raw and AVB images.

| Artifact | Size | SHA256 |
|---|---:|---|
| `linux-oneplus-hotdog-mainline616-6.16.0-r11.apk` | 25,502,518 bytes | `b499a6b3cf488e15d743e66a0965a74e30771e0cea6941040327498af154be6c` |
| APK `boot/vmlinuz` | 27,506,696 bytes | `89c6a92678c39fcd7f8e540b8f3706e9e5118b25de2b6842f134fd967a9fa243` |
| APK hotdog DTB | 139,676 bytes | `652bb1e48d974724ff0168ff40b60d54596d60b3a6dd232883c0ceb4abba291f` |
| Reused pmaports initramfs | 9,478,673 bytes | `347365a8e008a4f1d8b6788a6e933945a1eb940faa6af53b4057ba92d938c0bd` |
| Raw header-v2 boot image | 37,138,432 bytes | `0dd7bb041c334d9b902543867f038b993a7b1b0082f94e3ce1243e6692738b12` |
| Partition-sized AVB `boot.img` | 100,663,296 bytes | `4a4bffb60ce744f5fd5fc4070808699fb573a9350f24e60a5d59535aef5dc849` |
| Device nonfree-firmware subpackage | 1,439 bytes | `3650ea426041acd09fdca89fe4383a0f064a1f507505e8b6e722a9d71d599591` |

The AVB footer verifies successfully. Unpacking the final image reproduces the
exact r11 kernel, DTB, validated initramfs, and 397-byte command line.

## Hardware validation gate

The first `r11` run must preserve the accepted `r6` fallback, write only the
candidate slot, verify the complete partition readback, and attest the fresh
kernel, DTB, and boot-image hashes before accepting any runtime evidence.

Acceptance requires all of the following:

- RMTFS binds at `0xf2901000` without an assignment, XPU, or memory-overlap
  fault;
- the OpenRC service runs as `rmtfs -s -P -r`;
- MPSS loads the handset firmware, reaches `running`, and remains running;
- QRTR endpoints appear without a restart loop, firmware request failure, or
  remoteproc crash;
- WCN3990 remains disabled and no Wi-Fi result is inferred from this test; and
- display, UFS, writable rootfs, USB networking, SSH, touch, GPU, keys, and
  the separately accepted power path remain available.

Only after this isolated gate passes should a later revision enable WCN3990
and test Wi-Fi association and sustained traffic.
