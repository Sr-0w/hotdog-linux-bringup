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

## Recovery scope

Recovery selection is not yet claimed. The phone carries two different
100663296-byte recovery partitions with SHA-256
`299bdf0b3a30311be95418a3f8ae3f64209b661b15ded11b84b95b094439684a`
and `99f04ece06877cf30224e103f0e5099a1bd991174ca5c5aa1199b04eacc297d7`.
Neither matches an authorized recovery image currently present in the public
workspace, so entering recovery without a proven automatic return path would
be an unsafe test. The DT binding and helper support `recovery`; functional
validation remains pending an identified recovery image or explicit physical
fallback.
