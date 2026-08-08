// SPDX-License-Identifier: GPL-2.0-only
/* Inspect or apply the two SM8150 IFE write-port urgency fields. */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define CAMNOC_BASE 0x0ac42000UL
#define CAMNOC_SIZE 0x1000UL
#define IFE02_URGENCY 0x438
#define IFE13_URGENCY 0x838
#define WRITE_URGENCY_MASK 0x70
#define WRITE_URGENCY_VENDOR 0x30

static uint32_t read32(void *base, unsigned int offset)
{
	return *(volatile uint32_t *)((char *)base + offset);
}

static void update32(void *base, unsigned int offset, uint32_t mask,
		     uint32_t value)
{
	volatile uint32_t *reg = (volatile uint32_t *)((char *)base + offset);
	uint32_t current = *reg;

	*reg = (current & ~mask) | (value & mask);
	__sync_synchronize();
}

int main(int argc, char **argv)
{
	int write;
	uint32_t urgency = WRITE_URGENCY_VENDOR;
	int fd;
	void *mapping;

	if (argc == 1 || (argc == 2 && strcmp(argv[1], "show") == 0)) {
		write = 0;
	} else if (argc == 2 &&
		   strcmp(argv[1], "apply-vendor-urgency") == 0) {
		write = 1;
	} else if (argc == 2 && strcmp(argv[1], "clear-urgency") == 0) {
		write = 1;
		urgency = 0;
	} else {
		fprintf(stderr,
			"usage: %s [show|apply-vendor-urgency|clear-urgency]\n",
			argv[0]);
		return 2;
	}

	fd = open("/dev/mem", write ? O_RDWR | O_SYNC : O_RDONLY | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
		return 1;
	}

	mapping = mmap(NULL, CAMNOC_SIZE, write ? PROT_READ | PROT_WRITE : PROT_READ,
		       MAP_SHARED, fd, CAMNOC_BASE);
	if (mapping == MAP_FAILED) {
		fprintf(stderr, "mmap CAMNOC: %s\n", strerror(errno));
		close(fd);
		return 1;
	}

	printf("before ife02_urgency=0x%08x ife13_urgency=0x%08x\n",
	       read32(mapping, IFE02_URGENCY),
	       read32(mapping, IFE13_URGENCY));

	if (write) {
		update32(mapping, IFE02_URGENCY, WRITE_URGENCY_MASK,
			 urgency);
		update32(mapping, IFE13_URGENCY, WRITE_URGENCY_MASK,
			 urgency);
		printf("after  ife02_urgency=0x%08x ife13_urgency=0x%08x\n",
		       read32(mapping, IFE02_URGENCY),
		       read32(mapping, IFE13_URGENCY));
	}

	munmap(mapping, CAMNOC_SIZE);
	close(fd);
	return 0;
}
