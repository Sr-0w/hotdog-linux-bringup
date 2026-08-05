# Mainline 6.16 Flatpak/UFS crash isolation

Date: 2026-08-05

Device: OnePlus 7T Pro HD1913 (`hotdog`)

## Result

Revision `r17` enters Qualcomm `05c6:900e` while importing a large Flatpak
object, before application deployment. The failure is reproducible without
Discover by running Flatpak with `--no-deploy`, so neither the graphical
frontend nor the deployment transaction is required to trigger it.

The controlled pull used `com.play0ad.zeroad`, disabled related runtimes and
dependencies, forced UFS runtime power to `on`, and sampled storage state every
200 ms. The final traced object was staged through an unnamed file after a
3,508,827,314-byte `fallocate()`. During the following buffered writes, dirty
memory repeatedly reached roughly 470-570 MiB. USB and SSH then disappeared
and the device exposed Qualcomm crashdump.

Persistent crash memory contains no Linux panic, oops, UFS error, ext4 error,
or I/O timeout. Its final heartbeat still reports the UFS host as
`active/on`, the root loop device present, and the USB gadget configured. A
subsequent initramfs boot recovered a large orphan from the interrupted import.

## Negative controls

The same `r17` system completed all of these tests with UFS runtime power held
on:

- a direct 1 GiB read from `/dev/sda`;
- a direct 1 GiB root-filesystem write and SHA256 readback;
- 120 seconds of 4 KiB random direct I/O at queue depth 32, transferring about
  18.7 GiB without an error.

These controls show that ordinary direct I/O and runtime autosuspend alone do
not explain the Flatpak failure. The remaining distinguishing workload is a
large buffered OSTree import with sustained page-cache writeback.

## SMMU candidate

The current bring-up DT bypasses the Apps SMMU for UFS and relies on a
conditional 32-bit DMA mask. DWC3 previously produced the same abrupt
crashdump class until its Apps SMMU stream was restored and a translated domain
was selected. The next single-variable candidate therefore restores only:

```dts
&ufs_mem_hc {
    iommus = <&apps_smmu 0x300 0>;
    /delete-property/ qcom,ice;
};
```

The hardware-test image keeps the exact `r17` kernel, initramfs, command line,
and all other DT properties. A normalized DT comparison contains only the UFS
`iommus` addition. Its generated payloads are:

| Output | SHA256 |
|---|---|
| Kernel | `69aa8aba33e268538cabeec405ac0fc7baf802138219f161b2ad6832ce350f1c` |
| Initramfs | `347365a8e008a4f1d8b6788a6e933945a1eb940faa6af53b4057ba92d938c0bd` |
| UFS-SMMU DTB | `018006a67c60bf309a14fa70f224f0172d2aa718443a4deb4e0e6b5af2ad44be` |
| AVB boot image | `45bdebbd239b06bc15ea4f724a91321f897841c767822ab8f199a5be0ae2688c` |

The same change is committed as pmaports revision `r18`. Two strict builds
produced an identical 25,537,448-byte APK with SHA256
`06327deb007561a7acb7c2950d2714e640e2316996ca8815db46424405c5239e`.
The source-built kernel SHA256 is
`8115ce2bf6c126171ac0dd6afb1bec64a035d3aec8b76b89d12df2c6bfcf7e20`, and
the source-built DTB SHA256 is
`5df7f6adc14d92f47379da0bfb13e814f00c52b8934840d78e7fed4306174f17`.
Normalized source and A/B trees differ from `r17` by the same single property;
their binary DTB hashes differ because the two tools serialize it differently.

The generated captures remain outside the public repository. They may include
local network identifiers and are not needed to reproduce the test boundary.

## R18 hardware result

The DTB-only `r18` image booted directly, mounted the postmarketOS root,
restored USB networking and SSH, and placed `1d84000.ufshc` alone in IOMMU
group 4. The kernel reported a translated strict IOMMU domain and no Apps SMMU
fault.

The same pull-only Flatpak workload nevertheless entered `05c6:900e` at about
129 seconds. Immediately before transport disappeared, roughly 506 MiB was
dirty and 94 MiB was under writeback. The bounded 4 MiB ramoops capture again
contained no panic, oops, UFS error, ext4 error, or SMMU fault.

Restoring `iommus` also made the existing UFS workaround stop selecting a
32-bit DMA mask. Its condition applied only when the device-tree property was
absent, so this hardware run tested translated SMMU plus DMA64. It did not test
translated SMMU plus the previously successful 32-bit aperture.

## R19 SMMU plus DMA32 candidate

Revision `r19` keeps the exact UFS stream `0x300` attachment from `r18` and
changes only the SM8150 UFS DMA-mask selection. The host now requests a 32-bit
DMA aperture whether the controller is translated through the Apps SMMU or is
temporarily bypassing it. The package validator rejects any future source in
which that decision depends on the presence of `iommus`.

Two independent strict builds produced an identical 25,537,570-byte APK:

| Output | SHA256 |
|---|---|
| APK | `4b63e29866a9d11ceb024b68c213e999eed051eee578f2488208cb455e3d6e15` |
| Kernel | `ad44e6b0b4e8bd3b941dc2f5d2cfe9fdce4863444a2827a63a1b9546391ab069` |
| Source DTB | `5df7f6adc14d92f47379da0bfb13e814f00c52b8934840d78e7fed4306174f17` |

The hardware image uses the exact tested `r18` ramdisk, DTB, and command line;
only its kernel differs. The 96 MiB image passes AVB verification:

| Hardware-test component | SHA256 |
|---|---|
| Kernel | `ad44e6b0b4e8bd3b941dc2f5d2cfe9fdce4863444a2827a63a1b9546391ab069` |
| Initramfs | `347365a8e008a4f1d8b6788a6e933945a1eb940faa6af53b4057ba92d938c0bd` |
| Exact R18 DTB | `018006a67c60bf309a14fa70f224f0172d2aa718443a4deb4e0e6b5af2ad44be` |
| AVB boot image | `d32eedcd5f9fcaa0df975b92c1b8ff2bc5cce53afb9bb5848e45a335e8e57eb9` |

## R19 hardware result

Revision `r19` booted directly as `#20-oneplus-hotdog-mainline616`, mounted the
root filesystem read-write, restored USB networking and SSH, and kept the UFS
controller alone in translated IOMMU group 4. The kernel also confirmed that
the SM8150 UFS DMA mask was constrained to 32 bits.

The controlled Flatpak pull still entered `05c6:900e` after about 171.8
seconds while importing the same 3,508,827,314-byte object
`b4293a3d44299c42058f876346f805e4602d509c0dadd93767ea7e284ee85430.file`.
The final samples reported roughly 494 MiB dirty, 44 MiB under writeback, and
6,291,800 sectors written through the root loop device.

Revisions `r17`, `r18`, and `r19` therefore fail in the same narrow buffered
write range despite testing UFS without translation plus DMA32, translated
DMA64, and translated DMA32 respectively. Neither the missing Apps SMMU
attachment nor the DMA aperture is sufficient to explain the crash.

The first Sahara session exposed 48 firmware memory regions and yielded the
bounded 4 MiB ramoops reservation, again without a Linux panic. It also listed
a 256 KiB `KMSG.txt` region, but the previous capture helper could not request
that second range before the one-shot memory-debug session was consumed. The
capture path now retrieves both regions in the same connection.

## R20 legacy hardirq candidate

Linux commit `3c7ac40d7322` moved legacy UFS completion processing from the
hard interrupt handler into an `IRQF_ONESHOT` thread. Later upstream discussion
reported severe completion-latency regressions on UFSHC revisions older than
4.0. The HD1913 uses the legacy path, and an earlier visible failure included
`ufshcd_abort: cmd was completed, but without a notifying intr` immediately
before UFS recovery failed.

Revision `r20` restores only the pre-`3c7ac40d7322` hardirq completion path.
It retains the translated Apps SMMU stream and 32-bit DMA aperture proven by
`r19`. A strict pmbootstrap build produced:

| Output | SHA256 |
|---|---|
| APK | `b416b26d9bb08cb46c4f4ff2972258c09b9bc0a5c3d909dcf44b235805d49f2a` |
| Kernel | `496aa00a24c3ccdf9daad375d048c9ef253cabcbd6844c0b506dc8ca69212924` |

The AVB image changes only that kernel relative to the `r19` hardware image;
its ramdisk, serialized DTB, and command line are byte-identical:

| Hardware-test component | SHA256 |
|---|---|
| Kernel | `496aa00a24c3ccdf9daad375d048c9ef253cabcbd6844c0b506dc8ca69212924` |
| Initramfs | `347365a8e008a4f1d8b6788a6e933945a1eb940faa6af53b4057ba92d938c0bd` |
| Exact R18/R19 DTB | `018006a67c60bf309a14fa70f224f0172d2aa718443a4deb4e0e6b5af2ad44be` |
| AVB boot image | `9de1c7fcb58dea7ba6b0f73b8a2585f73f4211eee763b002cf65c82fe2d9fc38` |

Hardware validation remains pending.

## Safety

`test-flatpak-ufs-finalization.sh` never flashes or resets the phone. It splits
the operation into `pull` and `deploy`, streams the kernel and storage state to
the host, and performs only a read-only Sahara region-table listing plus bounded
ramoops and firmware `KMSG.txt` captures after `900e`. All reads share the
first crashdump session. A manual return to fastboot remains required from
Qualcomm crashdump mode.
