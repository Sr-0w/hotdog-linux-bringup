// SPDX-License-Identifier: GPL-2.0-only
#include <linux/init.h>
#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/platform_device.h>

#include "ufshcd.h"

#define HOTDOG_UFS_DEVICE_NAME "1d84000.ufshc"
#define HOTDOG_REG_UFS_HW_VERSION 0x0e4
#define HOTDOG_UFS_HW_VER_MAJOR_MASK GENMASK(31, 28)
#define HOTDOG_UFS_HW_VER_MINOR_MASK GENMASK(27, 16)
#define HOTDOG_UFS_HW_VER_STEP_MASK  GENMASK(15, 0)

static int __init hotdog_r6_ufs_regdump_init(void)
{
	struct device *dev;
	struct ufs_hba *hba;
	u32 version;
	int ret;

	dev = bus_find_device_by_name(&platform_bus_type, NULL,
				      HOTDOG_UFS_DEVICE_NAME);
	if (!dev)
		return -ENODEV;

	hba = dev_get_drvdata(dev);
	if (!hba) {
		ret = -ENODEV;
		goto out_put_device;
	}

	ret = ufshcd_hold(hba, false);
	if (ret)
		goto out_put_device;

	version = ufshcd_readl(hba, HOTDOG_REG_UFS_HW_VERSION);
	pr_info("HOTDOG_R6_UFS_HW_VERSION raw=0x%08x major=%u minor=%u step=%u\n",
		version,
		(version & HOTDOG_UFS_HW_VER_MAJOR_MASK) >> 28,
		(version & HOTDOG_UFS_HW_VER_MINOR_MASK) >> 16,
		version & HOTDOG_UFS_HW_VER_STEP_MASK);
	ufshcd_release(hba, false);

out_put_device:
	put_device(dev);
	return ret;
}

static void __exit hotdog_r6_ufs_regdump_exit(void)
{
	pr_info("HOTDOG_R6_UFS_REGDUMP_UNLOADED\n");
}

module_init(hotdog_r6_ufs_regdump_init);
module_exit(hotdog_r6_ufs_regdump_exit);

MODULE_DESCRIPTION("Clock-safe SM8150 UFS controller revision snapshot");
MODULE_AUTHOR("hotdog-linux-bringup contributors");
MODULE_LICENSE("GPL v2");
