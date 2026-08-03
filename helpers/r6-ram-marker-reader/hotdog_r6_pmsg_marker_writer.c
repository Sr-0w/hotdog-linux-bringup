// SPDX-License-Identifier: GPL-2.0-only
#include <linux/init.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/string.h>
#include <linux/types.h>

#include <asm/barrier.h>
#include <asm/cacheflush.h>

#define HOTDOG_PMSG_PHYS 0xa9bfeff0ULL
#define HOTDOG_PMSG_SIZE 0x1000
#define HOTDOG_PMSG_SIG 0x43474244U
#define HOTDOG_PMSG_MARKER_MAGIC 0x4d504448U
#define HOTDOG_PMSG_TEST_BUILD 0x00000001U
#define HOTDOG_PMSG_TEST_STAGE 0xfeed0002U

struct hotdog_pmsg_header {
	u32 sig;
	s32 start;
	s32 size;
};

struct hotdog_pmsg_marker {
	u32 magic;
	u32 build;
	u32 stage;
	u32 stage_inverse;
};

static int __init hotdog_r6_pmsg_marker_writer_init(void)
{
	struct hotdog_pmsg_marker *marker;
	struct hotdog_pmsg_header *header;
	void *mapping;

	mapping = memremap(HOTDOG_PMSG_PHYS, HOTDOG_PMSG_SIZE, MEMREMAP_WB);
	if (!mapping) {
		pr_err("HOTDOG_PMSG_TEST map_failed phys=%#llx size=%#x\n",
		       HOTDOG_PMSG_PHYS, HOTDOG_PMSG_SIZE);
		return -ENOMEM;
	}

	header = mapping;
	marker = mapping + sizeof(*header);
	WRITE_ONCE(header->sig, 0);
	WRITE_ONCE(header->start, sizeof(*marker));
	WRITE_ONCE(header->size, sizeof(*marker));
	WRITE_ONCE(marker->magic, HOTDOG_PMSG_MARKER_MAGIC);
	WRITE_ONCE(marker->build, HOTDOG_PMSG_TEST_BUILD);
	WRITE_ONCE(marker->stage, HOTDOG_PMSG_TEST_STAGE);
	WRITE_ONCE(marker->stage_inverse, ~HOTDOG_PMSG_TEST_STAGE);
	wmb();
	WRITE_ONCE(header->sig, HOTDOG_PMSG_SIG);
	wmb();
	flush_cache_all();
	mb();

	pr_info("HOTDOG_PMSG_TEST written sig=%08x start=%u size=%u magic=%08x build=%08x stage=%08x stage_inv=%08x\n",
		 HOTDOG_PMSG_SIG, sizeof(*marker), sizeof(*marker),
		 HOTDOG_PMSG_MARKER_MAGIC, HOTDOG_PMSG_TEST_BUILD,
		 HOTDOG_PMSG_TEST_STAGE, ~HOTDOG_PMSG_TEST_STAGE);
	memunmap(mapping);
	return 0;
}

static void __exit hotdog_r6_pmsg_marker_writer_exit(void)
{
}

module_init(hotdog_r6_pmsg_marker_writer_init);
module_exit(hotdog_r6_pmsg_marker_writer_exit);

MODULE_DESCRIPTION("One-shot R6 writer for the hotdog pmsg marker channel");
MODULE_AUTHOR("hotdog-linux-bringup contributors");
MODULE_LICENSE("GPL v2");
