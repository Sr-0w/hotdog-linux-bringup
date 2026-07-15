#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PMIC_ARB_CORE_PHYS 0x0c440000UL
#define PMIC_ARB_CORE_SIZE 0x00001100UL
#define PMIC_ARB_CNFG_PHYS 0x0c40a000UL
#define PMIC_ARB_CNFG_SIZE 0x00026000UL
#define PMIC_ARB_VERSION 0x0000UL
#define PMIC_ARB_FEATURES 0x0004UL
#define PMIC_ARB_APID_MAP 0x0900UL
#define PMIC_ARB_OWNER_MAP 0x0700UL
#define PMIC_ARB_FEATURES_PERIPH_MASK 0x07ffU
#define PM8150_PON_PPID 0x0008U

struct mapping {
	void *base;
	size_t length;
	size_t delta;
};

static int map_readonly(int fd, unsigned long phys, size_t size,
			struct mapping *mapping)
{
	long page_size = sysconf(_SC_PAGESIZE);
	unsigned long page_mask;
	unsigned long aligned;
	size_t delta;
	size_t length;

	if (page_size <= 0)
		return -1;
	page_mask = (unsigned long)page_size - 1;
	aligned = phys & ~page_mask;
	delta = (size_t)(phys - aligned);
	length = delta + size;

	mapping->base = mmap(NULL, length, PROT_READ, MAP_SHARED, fd,
				     (off_t)aligned);
	if (mapping->base == MAP_FAILED)
		return -1;
	mapping->length = length;
	mapping->delta = delta;
	return 0;
}

static uint32_t read32(const struct mapping *mapping, size_t offset)
{
	const volatile uint32_t *reg = (const volatile uint32_t *)
		((const unsigned char *)mapping->base + mapping->delta + offset);

	return *reg;
}

int main(void)
{
	struct mapping core = {0};
	struct mapping cnfg = {0};
	uint32_t version;
	uint32_t features;
	unsigned int count;
	unsigned int matches = 0;
	unsigned int apid;
	int fd;

	fd = open("/dev/mem", O_RDONLY | O_SYNC | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "open(/dev/mem): %s\n", strerror(errno));
		return 1;
	}
	if (map_readonly(fd, PMIC_ARB_CORE_PHYS, PMIC_ARB_CORE_SIZE, &core) < 0 ||
	    map_readonly(fd, PMIC_ARB_CNFG_PHYS, PMIC_ARB_CNFG_SIZE, &cnfg) < 0) {
		fprintf(stderr, "mmap PMIC arbiter: %s\n", strerror(errno));
		close(fd);
		return 1;
	}

	version = read32(&core, PMIC_ARB_VERSION);
	features = read32(&core, PMIC_ARB_FEATURES);
	count = features & PMIC_ARB_FEATURES_PERIPH_MASK;
	printf("version=0x%08" PRIx32 " features=0x%08" PRIx32
	       " apid_count=%u target_ppid=0x%03x\n",
	       version, features, count, PM8150_PON_PPID);

	for (apid = 0; apid < count; apid++) {
		size_t map_offset = PMIC_ARB_APID_MAP + 4U * apid;
		size_t owner_offset = PMIC_ARB_OWNER_MAP + 4U * apid;
		uint32_t map_value;
		uint32_t owner_value;
		unsigned int ppid;

		if (map_offset + sizeof(uint32_t) > PMIC_ARB_CORE_SIZE ||
		    owner_offset + sizeof(uint32_t) > PMIC_ARB_CNFG_SIZE)
			break;
		map_value = read32(&core, map_offset);
		ppid = (map_value >> 8) & 0x0fffU;
		if (ppid != PM8150_PON_PPID)
			continue;

		owner_value = read32(&cnfg, owner_offset);
		printf("match apid=%u map=0x%08" PRIx32
		       " owner=0x%08" PRIx32 " write_ee=%u irq_owner=%u"
		       " rw_phys=0x%08lx obs_phys=0x%08lx\n",
		       apid, map_value, owner_value, owner_value & 0x7U,
		       !!(map_value & (1U << 24)),
		       0x0c600000UL + 0x10000UL * apid,
		       0x0e600000UL + 0x80UL * apid);
		matches++;
	}

	munmap(cnfg.base, cnfg.length);
	munmap(core.base, core.length);
	close(fd);
	if (matches == 0) {
		fprintf(stderr, "no APID maps PM8150 PON PPID 0x008\n");
		return 2;
	}
	return 0;
}
