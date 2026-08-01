// SPDX-License-Identifier: GPL-2.0-only
#include <linux/init.h>
#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/platform_device.h>

#include "ufshcd.h"
#include "ufs-qcom.h"
#include "phy-qcom-ufs-i.h"

#define HOTDOG_UFS_DEVICE_NAME "1d84000.ufshc"
#define HOTDOG_UFS_HW_VER_MAJOR_MASK GENMASK(31, 28)
#define HOTDOG_UFS_HW_VER_MINOR_MASK GENMASK(27, 16)
#define HOTDOG_UFS_HW_VER_STEP_MASK  GENMASK(15, 0)

struct hotdog_mmio_reg {
	const char *name;
	u32 offset;
};

struct hotdog_dme_attr {
	const char *name;
	u32 selector;
};

static const struct hotdog_mmio_reg hotdog_host_regs[] = {
	{ "CONTROLLER_CAPABILITIES", REG_CONTROLLER_CAPABILITIES },
	{ "UFS_VERSION", REG_UFS_VERSION },
	{ "INTERRUPT_STATUS", REG_INTERRUPT_STATUS },
	{ "INTERRUPT_ENABLE", REG_INTERRUPT_ENABLE },
	{ "CONTROLLER_STATUS", REG_CONTROLLER_STATUS },
	{ "CONTROLLER_ENABLE", REG_CONTROLLER_ENABLE },
	{ "UTP_TRANSFER_REQ_DOOR_BELL", REG_UTP_TRANSFER_REQ_DOOR_BELL },
	{ "UTP_TASK_REQ_DOOR_BELL", REG_UTP_TASK_REQ_DOOR_BELL },
	{ "UFS_SYS1CLK_1US", REG_UFS_SYS1CLK_1US },
	{ "UFS_TX_SYMBOL_CLK_NS_US", REG_UFS_TX_SYMBOL_CLK_NS_US },
	{ "UFS_PA_LINK_STARTUP_TIMER", REG_UFS_PA_LINK_STARTUP_TIMER },
	{ "UFS_CFG1", REG_UFS_CFG1 },
	{ "UFS_CFG2", REG_UFS_CFG2 },
	{ "UFS_HW_VERSION", REG_UFS_HW_VERSION },
	{ "UFS_UNIPRO_CFG", UFS_UNIPRO_CFG },
	{ "UFS_AH8_CFG", UFS_AH8_CFG },
};

/* SM8150 QMP v4 offsets used by the downstream Gear 3 calibration path. */
static const struct hotdog_mmio_reg hotdog_phy_regs[] = {
	{ "PHY_START", 0xc00 },
	{ "POWER_DOWN_CONTROL", 0xc04 },
	{ "SW_RESET", 0xc08 },
	{ "TIMER_20US_CORECLK_STEPS_MSB", 0xc0c },
	{ "TIMER_20US_CORECLK_STEPS_LSB", 0xc10 },
	{ "PLL_CNTL", 0xc2c },
	{ "TX_HSGEAR_CAPABILITY", 0xc74 },
	{ "RX_HSGEAR_CAPABILITY", 0xcb4 },
	{ "DEBUG_BUS_CLKSEL", 0xd24 },
	{ "LINECFG_DISABLE", 0xd48 },
	{ "RX_MIN_HIBERN8_TIME", 0xd50 },
	{ "RX_SIGDET_CTRL2", 0xd58 },
	{ "TX_PWM_GEAR_BAND", 0xd60 },
	{ "TX_HS_GEAR_BAND", 0xd68 },
	{ "PCS_READY_STATUS", 0xd80 },
	{ "TX_MID_TERM_CTRL1", 0xdd8 },
	{ "MULTI_LANE_CTRL1", 0xde0 },
	{ "TX0_PWM_GEAR_1", 0x4d8 },
	{ "TX0_PWM_GEAR_2", 0x4dc },
	{ "TX0_PWM_GEAR_3", 0x4e0 },
	{ "TX0_PWM_GEAR_4", 0x4e4 },
	{ "TX0_LANE_MODE_1", 0x484 },
	{ "TX0_TRAN_DRVR_EMP_EN", 0x4b8 },
	{ "RX0_UCDR_FO_GAIN", 0x608 },
	{ "RX0_UCDR_SO_GAIN", 0x614 },
	{ "RX0_UCDR_SO_SATURATION_AND_ENABLE", 0x634 },
	{ "RX0_UCDR_PI_CTRL2", 0x648 },
	{ "RX0_RX_TERM_BW", 0x680 },
	{ "RX0_SIGDET_CNTRL", 0x71c },
	{ "RX0_SIGDET_LVL", 0x720 },
	{ "RX0_SIGDET_DEGLITCH_CNTRL", 0x724 },
	{ "RX0_RX_MODE_00_LOW", 0x770 },
	{ "RX0_RX_MODE_00_HIGH", 0x774 },
	{ "RX0_RX_MODE_00_HIGH2", 0x778 },
	{ "RX0_RX_MODE_00_HIGH3", 0x77c },
	{ "RX0_RX_MODE_00_HIGH4", 0x780 },
	{ "TX1_PWM_GEAR_1", 0x8d8 },
	{ "TX1_PWM_GEAR_2", 0x8dc },
	{ "TX1_PWM_GEAR_3", 0x8e0 },
	{ "TX1_PWM_GEAR_4", 0x8e4 },
	{ "TX1_LANE_MODE_1", 0x884 },
	{ "TX1_TRAN_DRVR_EMP_EN", 0x8b8 },
	{ "RX1_UCDR_FO_GAIN", 0xa08 },
	{ "RX1_UCDR_SO_GAIN", 0xa14 },
	{ "RX1_UCDR_SO_SATURATION_AND_ENABLE", 0xa34 },
	{ "RX1_UCDR_PI_CTRL2", 0xa48 },
	{ "RX1_RX_TERM_BW", 0xa80 },
	{ "RX1_SIGDET_CNTRL", 0xb1c },
	{ "RX1_SIGDET_LVL", 0xb20 },
	{ "RX1_SIGDET_DEGLITCH_CNTRL", 0xb24 },
	{ "RX1_RX_MODE_00_LOW", 0xb70 },
	{ "RX1_RX_MODE_00_HIGH", 0xb74 },
	{ "RX1_RX_MODE_00_HIGH2", 0xb78 },
	{ "RX1_RX_MODE_00_HIGH3", 0xb7c },
	{ "RX1_RX_MODE_00_HIGH4", 0xb80 },
};

static const struct hotdog_dme_attr hotdog_dme_attrs[] = {
	{ "DME_VS_CORE_CLK_CTRL", UIC_ARG_MIB(DME_VS_CORE_CLK_CTRL) },
	{ "PA_VS_CORE_CLK_40NS_CYCLES", UIC_ARG_MIB(PA_VS_CORE_CLK_40NS_CYCLES) },
	{ "PA_VS_CONFIG_REG1", UIC_ARG_MIB(PA_VS_CONFIG_REG1) },
	{ "PA_LOCAL_TX_LCC_ENABLE", UIC_ARG_MIB(PA_LOCAL_TX_LCC_ENABLE) },
	{ "PA_CONNECTEDTXDATALANES", UIC_ARG_MIB(PA_CONNECTEDTXDATALANES) },
	{ "PA_CONNECTEDRXDATALANES", UIC_ARG_MIB(PA_CONNECTEDRXDATALANES) },
	{ "PA_MAXRXHSGEAR", UIC_ARG_MIB(PA_MAXRXHSGEAR) },
	{ "MPHY_TX_FSM_STATE_L0", UIC_ARG_MIB_SEL(MPHY_TX_FSM_STATE, 0) },
	{ "MPHY_TX_FSM_STATE_L1", UIC_ARG_MIB_SEL(MPHY_TX_FSM_STATE, 1) },
	{ "MPHY_RX_FSM_STATE_L0", UIC_ARG_MIB_SEL(MPHY_RX_FSM_STATE, 0) },
	{ "MPHY_RX_FSM_STATE_L1", UIC_ARG_MIB_SEL(MPHY_RX_FSM_STATE, 1) },
};

static void hotdog_dump_mmio(const char *domain, void __iomem *base,
			     const struct hotdog_mmio_reg *regs, size_t count)
{
	size_t i;

	for (i = 0; i < count; i++)
		pr_info("HOTDOG_R6_UFS_%s name=%s offset=0x%04x value=0x%08x\n",
			domain, regs[i].name, regs[i].offset,
			readl_relaxed(base + regs[i].offset));
}

static void hotdog_dump_dme(struct ufs_hba *hba)
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(hotdog_dme_attrs); i++) {
		u32 value = 0;
		int ret;

		ret = ufshcd_dme_get(hba, hotdog_dme_attrs[i].selector, &value);
		pr_info("HOTDOG_R6_UFS_DME name=%s selector=0x%08x ret=%d value=0x%08x\n",
			hotdog_dme_attrs[i].name,
			hotdog_dme_attrs[i].selector, ret, value);
	}
}

static int __init hotdog_r6_ufs_regdump_init(void)
{
	struct device *dev;
	struct ufs_hba *hba;
	struct ufs_qcom_host *host;
	struct ufs_qcom_phy *phy;
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

	version = ufshcd_readl(hba, REG_UFS_HW_VERSION);
	pr_info("HOTDOG_R6_UFS_HW_VERSION raw=0x%08x major=%u minor=%u step=%u\n",
		version,
		(u32)((version & HOTDOG_UFS_HW_VER_MAJOR_MASK) >> 28),
		(u32)((version & HOTDOG_UFS_HW_VER_MINOR_MASK) >> 16),
		(u32)(version & HOTDOG_UFS_HW_VER_STEP_MASK));
	pr_info("HOTDOG_R6_UFS_STATE ufshcd=%u dev_power=%u link=%u gear_rx=%u gear_tx=%u lane_rx=%u lane_tx=%u pwr_rx=%u pwr_tx=%u hs_rate=%u\n",
		hba->ufshcd_state, hba->curr_dev_pwr_mode, hba->uic_link_state,
		hba->pwr_info.gear_rx, hba->pwr_info.gear_tx,
		hba->pwr_info.lane_rx, hba->pwr_info.lane_tx,
		hba->pwr_info.pwr_rx, hba->pwr_info.pwr_tx,
		hba->pwr_info.hs_rate);

	hotdog_dump_mmio("HOST", hba->mmio_base, hotdog_host_regs,
			  ARRAY_SIZE(hotdog_host_regs));

	host = ufshcd_get_variant(hba);
	if (!host || !host->generic_phy) {
		pr_err("HOTDOG_R6_UFS_PHY unavailable\n");
	} else {
		phy = get_ufs_qcom_phy(host->generic_phy);
		if (!phy || !phy->mmio) {
			pr_err("HOTDOG_R6_UFS_PHY MMIO unavailable\n");
		} else {
			pr_info("HOTDOG_R6_UFS_PHY_STATE powered=%u lanes=%u iface_clk=%u ref_clk=%u dev_ref_clk=%u\n",
				phy->is_powered_on, phy->lanes_per_direction,
				phy->is_iface_clk_enabled, phy->is_ref_clk_enabled,
				phy->is_dev_ref_clk_enabled);
			hotdog_dump_mmio("PHY", phy->mmio, hotdog_phy_regs,
					  ARRAY_SIZE(hotdog_phy_regs));
		}
	}

	hotdog_dump_dme(hba);
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

MODULE_DESCRIPTION("Clock-safe read-only SM8150 UFS host and PHY snapshot");
MODULE_AUTHOR("hotdog-linux-bringup contributors");
MODULE_LICENSE("GPL v2");
