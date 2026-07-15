#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define APSS_WDT_PHYS 0x17c10000UL
#define WDT_RST 0x04
#define WDT_EN 0x08
#define WDT_STS 0x0c
#define WDT_BARK_TIME 0x10
#define WDT_BITE_TIME 0x14

static uint32_t read_reg(volatile uint8_t *base, size_t offset)
{
	return *(volatile uint32_t *)(base + offset);
}

static void show_registers(volatile uint8_t *base, const char *label)
{
	printf("%s rst=0x%08" PRIx32 " en=0x%08" PRIx32
	       " sts=0x%08" PRIx32 " bark=0x%08" PRIx32
	       " bite=0x%08" PRIx32 "\n",
	       label, read_reg(base, WDT_RST), read_reg(base, WDT_EN),
	       read_reg(base, WDT_STS), read_reg(base, WDT_BARK_TIME),
	       read_reg(base, WDT_BITE_TIME));
}

int main(int argc, char **argv)
{
	const bool disable = argc == 2 && strcmp(argv[1], "--disable") == 0;
	const long page_size = sysconf(_SC_PAGESIZE);
	void *mapping;
	int fd;

	if (argc > 2 || (argc == 2 && !disable)) {
		fprintf(stderr, "usage: %s [--disable]\n", argv[0]);
		return 2;
	}
	if (page_size <= 0 || APSS_WDT_PHYS % (unsigned long)page_size != 0) {
		fprintf(stderr, "unsupported page size: %ld\n", page_size);
		return 3;
	}

	fd = open("/dev/mem", disable ? O_RDWR | O_SYNC : O_RDONLY | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
		return 4;
	}
	mapping = mmap(NULL, (size_t)page_size,
		       disable ? PROT_READ | PROT_WRITE : PROT_READ,
		       MAP_SHARED, fd, (off_t)APSS_WDT_PHYS);
	if (mapping == MAP_FAILED) {
		fprintf(stderr, "mmap 0x%lx: %s\n", APSS_WDT_PHYS,
			strerror(errno));
		close(fd);
		return 5;
	}

	show_registers(mapping, "before");
	if (disable) {
		*(volatile uint32_t *)((volatile uint8_t *)mapping + WDT_EN) = 0;
		__sync_synchronize();
		show_registers(mapping, "after");
		if (read_reg(mapping, WDT_EN) != 0) {
			fprintf(stderr, "watchdog enable register did not clear\n");
			munmap(mapping, (size_t)page_size);
			close(fd);
			return 6;
		}
	}

	munmap(mapping, (size_t)page_size);
	close(fd);
	return 0;
}
