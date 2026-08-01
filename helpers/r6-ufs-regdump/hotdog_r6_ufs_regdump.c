// SPDX-License-Identifier: GPL-2.0-only
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>

/*
 * The original experiment tried to wake the downstream UFS controller with
 * its clock-hold API before reading registers. On the tested hotdog that call
 * timed out while leaving hibern8, entered broken vendor error recovery, and
 * wedged module loading. Keep this module as a fail-closed record so an old
 * build command cannot repeat the hardware interaction.
 */
static int __init hotdog_r6_ufs_regdump_init(void)
{
	pr_err("HOTDOG_R6_UFS_REGDUMP_DISABLED: live probing is unsafe; use boot-time logs\n");
	return -EPERM;
}

static void __exit hotdog_r6_ufs_regdump_exit(void)
{
}

module_init(hotdog_r6_ufs_regdump_init);
module_exit(hotdog_r6_ufs_regdump_exit);

MODULE_DESCRIPTION("Disabled hotdog R6 UFS live-probe experiment");
MODULE_AUTHOR("hotdog-linux-bringup contributors");
MODULE_LICENSE("GPL v2");
