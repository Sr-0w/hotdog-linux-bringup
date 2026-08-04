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

## Safety

`test-flatpak-ufs-finalization.sh` never flashes or resets the phone. It splits
the operation into `pull` and `deploy`, streams the kernel and storage state to
the host, and performs only a bounded read-only ramoops capture after `900e`.
A manual return to fastboot remains required from Qualcomm crashdump mode.
