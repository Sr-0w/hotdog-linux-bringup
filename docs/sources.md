# Source trees

External repositories are cloned under the ignored `src/` directory. They are
not vendored into this repository.

## Primary sources

| Source | Role |
|---|---|
| [postmarketOS pmbootstrap](https://gitlab.postmarketos.org/postmarketOS/pmbootstrap) | Build and image tooling. |
| [postmarketOS pmaports](https://gitlab.postmarketos.org/postmarketOS/pmaports) | Official packages and Qualcomm SM8150 kernel packaging. |
| [sm8150-linux-mainline pmaports](https://github.com/sm8150-linux-mainline/pmaports) | Existing SM8150 device ports and hotdog packaging reference. |
| [postmarketOS Qualcomm SM8150 Linux](https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux) | Pinned Linux 6.17 K1 source and exact hotdog DTB reproduction. |
| [OnePlus SM8150 kernel](https://github.com/OnePlusOSS/android_kernel_oneplus_sm8150) | Vendor kernel and hardware descriptions. |
| [LineageOS hotdog device tree](https://github.com/LineageOS/android_device_oneplus_hotdog) | Android partition, firmware, and device configuration reference. |
| [LineageOS SM8150 kernel](https://github.com/LineageOS/android_kernel_oneplus_sm8150) | Working downstream kernel reference. |
| [Linux mainline](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git) | Upstream target and comparison base. |

## Additional references

The following projects informed boot and display investigation but are not the
project target:

- [BotchedRPR/hotdog-halium-kernel](https://github.com/BotchedRPR/hotdog-halium-kernel)
- [ClearStaff/linux-sm8150-mainline-hotdog](https://github.com/ClearStaff/linux-sm8150-mainline-hotdog)
- postmarketOS device wiki pages for `oneplus-hotdog`

The goal remains a pmaports-compatible postmarketOS port, not a permanent
Halium or vendor-kernel distribution.

## Bootstrap behavior

`scripts/bootstrap-sources.sh` clones or fetches the common repositories. It
does not reset local branches or discard local changes.

```bash
./scripts/bootstrap-sources.sh --sm8150-k1
```

Record source commits whenever publishing a hardware result. A branch name
alone is not sufficient evidence because these trees move independently.
