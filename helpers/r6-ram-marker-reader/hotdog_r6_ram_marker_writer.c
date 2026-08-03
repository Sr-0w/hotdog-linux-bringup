// SPDX-License-Identifier: GPL-2.0-only
#include <linux/init.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/types.h>

#include <asm/barrier.h>
#include <asm/cacheflush.h>

#define HOTDOG_COMPACT_MARKER_PHYS 0xa9bffff0ULL
#define HOTDOG_COMPACT_MARKER_SIZE 0x10
#define HOTDOG_COMPACT_MARKER_MAGIC 0x4d524448U
#define HOTDOG_COMPACT_TEST_BUILD 0x00000001U
#define HOTDOG_COMPACT_TEST_STAGE 0xfeed0001U

struct hotdog_compact_marker {
	u32 magic;
	u32 build;
	u32 stage;
	u32 stage_inverse;
};

static int __init hotdog_r6_ram_marker_writer_init(void)
{
	struct hotdog_compact_marker *record;
	void *mapping;

	mapping = memremap(HOTDOG_COMPACT_MARKER_PHYS,
			   HOTDOG_COMPACT_MARKER_SIZE, MEMREMAP_WB);
	if (!mapping) {
		pr_err("HOTDOG_RAM_COMPACT_TEST map_failed phys=%#llx size=%#x\n",
		       HOTDOG_COMPACT_MARKER_PHYS,
		       HOTDOG_COMPACT_MARKER_SIZE);
		return -ENOMEM;
	}

	record = mapping;
	WRITE_ONCE(record->magic, 0);
	WRITE_ONCE(record->build, HOTDOG_COMPACT_TEST_BUILD);
	WRITE_ONCE(record->stage, HOTDOG_COMPACT_TEST_STAGE);
	WRITE_ONCE(record->stage_inverse, ~HOTDOG_COMPACT_TEST_STAGE);
	wmb();
	WRITE_ONCE(record->magic, HOTDOG_COMPACT_MARKER_MAGIC);
	wmb();
	flush_cache_all();
	mb();

	pr_info("HOTDOG_RAM_COMPACT_TEST written magic=%08x build=%08x stage=%08x stage_inv=%08x\n",
		 HOTDOG_COMPACT_MARKER_MAGIC, HOTDOG_COMPACT_TEST_BUILD,
		 HOTDOG_COMPACT_TEST_STAGE, ~HOTDOG_COMPACT_TEST_STAGE);
	memunmap(mapping);
	return 0;
}

static void __exit hotdog_r6_ram_marker_writer_exit(void)
{
}

module_init(hotdog_r6_ram_marker_writer_init);
module_exit(hotdog_r6_ram_marker_writer_exit);

MODULE_DESCRIPTION("One-shot R6 writer for the hotdog compact RAM marker");
MODULE_AUTHOR("hotdog-linux-bringup contributors");
MODULE_LICENSE("GPL v2");
