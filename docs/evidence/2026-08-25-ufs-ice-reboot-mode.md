# UFS ICE and reboot-mode hardware validation

The running mainline 6.16 image now restores the upstream SM8150 UFS
`qcom,ice` link and carries the primary PM8150/syscon reboot-mode description.
It was written to `boot_b` only after a complete partition backup and exact
readback performed in the preceding hardware session.

## UFS ICE

After a real fresh boot, the loaded device tree contains `qcom,ice`,
`1d90000.crypto` is bound, and `/sys/block/sda/queue/crypto` exposes
`max_dun_bits`, `modes`, `num_keyslots` and `raw_keys`. AES-256-XTS reports
`0x1fe00`. The root filesystem mounted normally, `rmtfs` remained active and
the kernel logged zero module section-size errors.

This proves the ICE hardware and blk-crypto integration are operational. It
does not claim that the current root filesystem data is encrypted; that needs
a separately provisioned encrypted volume and ciphertext/readback test.

## Bootloader reboot mode

BusyBox `reboot` cannot transport a mode string. The first Python helper also
called the one-argument libc `reboot()` wrapper with four arguments and returned
`EINVAL`, so that attempt was invalid. The corrected helper invokes aarch64
syscall 142 directly with Linux reboot magic and
`LINUX_REBOOT_CMD_RESTART2`.

From boot ID `8e3bab61-8334-4e1e-8b6a-78c529270b15`, the corrected
`RESTART2("bootloader")` reached protocol-valid bootloader fastboot after ten
seconds. Fastboot reported product `msmnile`, current slot `b` and
`is-userspace: no`. No partition was written. `fastboot reboot` returned to
postmarketOS after 75 seconds with a different boot ID. ICE, reboot-mode,
`rmtfs`, rootfs free space and the zero module-error count remained healthy.

Evidence directory: `logs/2026-08-25-ice-reboot-mode-handoff`.

| Evidence | SHA-256 |
| --- | --- |
| `00-preflight.txt` | `a022679a95396c23c4055b55c2429a6140d0ff87f47180cc1575a7ce9213fcb7` |
| `02-bootloader-result.txt` | `6fe4975b7025ee0a9246aa3b74effd606a69d470e14a09fe531d1ee7ca7bdefc` |
| `03-fastboot-attestation.txt` | `db09d20ef65547416007775c96870aa8295d6ce5785d3956461bee31834a4238` |
| `04-fastboot-reboot.txt` | `ac672d2f42935eacabc56e7f3666ac2af448fcf4cdf48072f5a0c4cef4f14b55` |
| `05-pmos-return.txt` | `0180480c303e5451d6e5bc30f5cb1b9feb28c4d738ede35dc6e13c01e528fcb9` |

## Recovery mode

With explicit acceptance of a possible physical reset, the same helper was
tested with `RESTART2("recovery")`. Recovery appeared after ten seconds as an
authorized ADB target:

```
state: recovery
product: OnePlus7TPro
model: HD1911
build type: userdebug
shell: uid=0(root), SELinux context u:r:su:s0
```

The user also confirmed the recovery UI physically. `adb reboot system`
returned to postmarketOS after 42 seconds with a new boot ID. ICE still exposed
AES-256-XTS `0x1fe00`, reboot-mode remained bound, `rmtfs` was active and no
module section-size error appeared.

Evidence directory: `logs/2026-08-25-recovery-mode-handoff`.

| Evidence | SHA-256 |
| --- | --- |
| `00-preflight.txt` | `fb662b14f796fe37d11979d4ac3b03170c3b2ebc9b9208a178f295d7e0e9f804` |
| `02-result.txt` | `8b1db9770e483ae3ba885b2152f8d3d4370666f9eb307dc56a2408039fb39693` |
| `04-adb-attestation.txt` | `7e3ceb912c474b98fc4e6a37b73d45acebaa9c5d0f9750bcec856a8e5b4c5b86` |
| `05-adb-reboot-system.txt` | `502627cece5661ab31714064ed499341d77ebbec0298a41e08c738ec9f988e3fb` |
| `06-pmos-return.txt` | `ed48307dbe4f3fa9d7c8d02bb856b23b3d0f2863e494fdc8ae0d28864352bbb4` |

This validates recovery selection and the existing Android/Lineage recovery
path. A native postmarketOS recovery image is not supplied yet. Building one
with an authorized rescue shell, A/B inspection, verified image write/readback
and rollback remains a separate installation deliverable.
