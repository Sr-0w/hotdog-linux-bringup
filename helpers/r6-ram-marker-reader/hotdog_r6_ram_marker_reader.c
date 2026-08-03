// SPDX-License-Identifier: GPL-2.0-only
#include <linux/init.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/types.h>

#define HOTDOG_LEGACY_MARKER_PHYS 0xa9bff000ULL
#define HOTDOG_LEGACY_MARKER_SIZE 0x60
#define HOTDOG_LEGACY_MARKER_MAGIC 0x36315343U
#define HOTDOG_LEGACY_MARKER_BUILD 0x00060001U
#define HOTDOG_COMPACT_MARKER_PHYS 0xa9bffff0ULL
#define HOTDOG_COMPACT_MARKER_SIZE 0x10
#define HOTDOG_COMPACT_MARKER_MAGIC 0x4d524448U
#define HOTDOG_PMSG_PHYS 0xa9bfeff0ULL
#define HOTDOG_PMSG_READ_SIZE 0x1c
#define HOTDOG_PMSG_SIG 0x43474244U
#define HOTDOG_PMSG_MARKER_MAGIC 0x4d504448U

struct hotdog_marker_record {
	u32 magic;
	u32 build;
	u32 stage;
	u32 stage_inverse;
	u32 tag;
	u32 tag_inverse;
	u32 reserved[2];
};

struct hotdog_compact_marker {
	u32 magic;
	u32 build;
	u32 stage;
	u32 stage_inverse;
};

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

static int __init hotdog_r6_ram_marker_reader_init(void)
{
	const struct hotdog_marker_record *records;
	void *mapping;
	unsigned int i;

	mapping = memremap(HOTDOG_LEGACY_MARKER_PHYS,
			   HOTDOG_LEGACY_MARKER_SIZE,
			   MEMREMAP_WB);
	if (!mapping) {
		pr_err("HOTDOG_RAM_MARKER map_failed phys=%#llx size=%#x\n",
		       HOTDOG_LEGACY_MARKER_PHYS,
		       HOTDOG_LEGACY_MARKER_SIZE);
		return -ENOMEM;
	}

	records = mapping;
	for (i = 0; i < 3; i++) {
		const struct hotdog_marker_record *record = &records[i];
		bool valid = record->magic == HOTDOG_LEGACY_MARKER_MAGIC &&
			record->build == HOTDOG_LEGACY_MARKER_BUILD &&
			record->stage_inverse == ~record->stage &&
			record->tag_inverse == ~record->tag;

		pr_info("HOTDOG_RAM_MARKER slot=%u valid=%u magic=%08x build=%08x stage=%08x stage_inv=%08x tag=%08x tag_inv=%08x\n",
			i, valid, record->magic, record->build,
			record->stage, record->stage_inverse,
			record->tag, record->tag_inverse);
	}

	memunmap(mapping);

	mapping = memremap(HOTDOG_COMPACT_MARKER_PHYS,
			   HOTDOG_COMPACT_MARKER_SIZE,
			   MEMREMAP_WB);
	if (!mapping) {
		pr_err("HOTDOG_RAM_COMPACT map_failed phys=%#llx size=%#x\n",
		       HOTDOG_COMPACT_MARKER_PHYS,
		       HOTDOG_COMPACT_MARKER_SIZE);
		return -ENOMEM;
	}

	{
		const struct hotdog_compact_marker *record = mapping;
		bool valid = record->magic == HOTDOG_COMPACT_MARKER_MAGIC &&
			record->stage_inverse == ~record->stage;

		pr_info("HOTDOG_RAM_COMPACT valid=%u magic=%08x build=%08x stage=%08x stage_inv=%08x\n",
			valid, record->magic, record->build,
			record->stage, record->stage_inverse);
	}

	memunmap(mapping);

	mapping = memremap(HOTDOG_PMSG_PHYS, HOTDOG_PMSG_READ_SIZE,
			   MEMREMAP_WB);
	if (!mapping) {
		pr_err("HOTDOG_PMSG_MARKER map_failed phys=%#llx size=%#x\n",
		       HOTDOG_PMSG_PHYS, HOTDOG_PMSG_READ_SIZE);
		return -ENOMEM;
	}

	{
		const struct hotdog_pmsg_header *header = mapping;
		const struct hotdog_pmsg_marker *marker =
			mapping + sizeof(*header);
		bool valid = header->sig == HOTDOG_PMSG_SIG &&
			header->start == sizeof(*marker) &&
			header->size == sizeof(*marker) &&
			marker->magic == HOTDOG_PMSG_MARKER_MAGIC &&
			marker->stage_inverse == ~marker->stage;

		pr_info("HOTDOG_PMSG_MARKER valid=%u sig=%08x start=%08x size=%08x magic=%08x build=%08x stage=%08x stage_inv=%08x\n",
			valid, header->sig, header->start, header->size,
			marker->magic, marker->build, marker->stage,
			marker->stage_inverse);
	}

	memunmap(mapping);
	return 0;
}

static void __exit hotdog_r6_ram_marker_reader_exit(void)
{
}

module_init(hotdog_r6_ram_marker_reader_init);
module_exit(hotdog_r6_ram_marker_reader_exit);

MODULE_DESCRIPTION("Read-only hotdog direct-entry RAM checkpoint reader");
MODULE_AUTHOR("hotdog-linux-bringup contributors");
MODULE_LICENSE("GPL v2");
