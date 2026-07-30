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

#ifndef DEVMEM_PATH
#define DEVMEM_PATH "/dev/mem"
#endif

#define APSS_WDT_PHYS 0x17c10000UL
#define IMEM_RESTART_REASON_PHYS 0x146bf65cUL
#define RESTART_REASON_BOOTLOADER 0x77665500U
#define RESTART_REASON_NORMAL 0x77665501U
#define WDT_RATE 32764U
#define MIN_TIMEOUT_SEC 10U
#define MAX_TIMEOUT_SEC 3600U
#define WDT_RST 0x04
#define WDT_EN 0x08
#define WDT_STS 0x0c
#define WDT_BARK_TIME 0x10
#define WDT_BITE_TIME 0x14

enum operation {
	OP_SHOW,
	OP_DISABLE,
	OP_DISARM,
	OP_ARM_BOOTLOADER,
};

static uint32_t read_reg(volatile uint8_t *base, size_t offset)
{
	return *(volatile uint32_t *)(base + offset);
}

static void write_reg(volatile uint8_t *base, size_t offset, uint32_t value)
{
	*(volatile uint32_t *)(base + offset) = value;
	__sync_synchronize();
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

static void usage(const char *name)
{
	fprintf(stderr,
		"usage: %s [--disable | --disarm | --arm-bootloader SECONDS]\n",
		name);
}

static bool parse_timeout(const char *value, uint32_t *timeout_sec)
{
	char *end = NULL;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(value, &end, 10);
	if (errno != 0 || end == value || *end != '\0' ||
	    parsed < MIN_TIMEOUT_SEC || parsed > MAX_TIMEOUT_SEC)
		return false;

	*timeout_sec = (uint32_t)parsed;
	return true;
}

int main(int argc, char **argv)
{
	enum operation operation = OP_SHOW;
	uint32_t timeout_sec = 0;
	const long page_size = sysconf(_SC_PAGESIZE);
	const unsigned long imem_page =
		IMEM_RESTART_REASON_PHYS & ~((unsigned long)page_size - 1);
	const size_t imem_offset =
		(size_t)(IMEM_RESTART_REASON_PHYS - imem_page);
	const bool write_access = argc > 1;
	void *wdt_mapping;
	void *imem_mapping = MAP_FAILED;
	volatile uint8_t *wdt;
	volatile uint8_t *imem = NULL;
	uint32_t ticks;
	int fd;

	if (argc == 2 && strcmp(argv[1], "--disable") == 0) {
		operation = OP_DISABLE;
	} else if (argc == 2 && strcmp(argv[1], "--disarm") == 0) {
		operation = OP_DISARM;
	} else if (argc == 3 &&
		   strcmp(argv[1], "--arm-bootloader") == 0 &&
		   parse_timeout(argv[2], &timeout_sec)) {
		operation = OP_ARM_BOOTLOADER;
	} else if (argc != 1) {
		usage(argv[0]);
		return 2;
	}
	if (page_size <= 0 || APSS_WDT_PHYS % (unsigned long)page_size != 0) {
		fprintf(stderr, "unsupported page size: %ld\n", page_size);
		return 3;
	}

	fd = open(DEVMEM_PATH,
		  write_access ? O_RDWR | O_SYNC : O_RDONLY | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", DEVMEM_PATH, strerror(errno));
		return 4;
	}
	wdt_mapping = mmap(NULL, (size_t)page_size,
			   write_access ? PROT_READ | PROT_WRITE : PROT_READ,
			   MAP_SHARED, fd, (off_t)APSS_WDT_PHYS);
	if (wdt_mapping == MAP_FAILED) {
		fprintf(stderr, "mmap 0x%lx: %s\n", APSS_WDT_PHYS,
			strerror(errno));
		close(fd);
		return 5;
	}
	wdt = wdt_mapping;

	if (operation == OP_DISARM || operation == OP_ARM_BOOTLOADER) {
		imem_mapping = mmap(NULL, (size_t)page_size,
				   PROT_READ | PROT_WRITE, MAP_SHARED, fd,
				   (off_t)imem_page);
		if (imem_mapping == MAP_FAILED) {
			fprintf(stderr, "mmap 0x%lx: %s\n", imem_page,
				strerror(errno));
			munmap(wdt_mapping, (size_t)page_size);
			close(fd);
			return 6;
		}
		imem = imem_mapping;
	}

	printf("HOTDOG_APSS_WDT_CONTROL_V2\n");
	show_registers(wdt, "before");
	if (operation == OP_DISABLE || operation == OP_DISARM) {
		write_reg(wdt, WDT_EN, 0);
		if (operation == OP_DISARM)
			write_reg(imem, imem_offset, RESTART_REASON_NORMAL);
		show_registers(wdt, "after");
		if (read_reg(wdt, WDT_EN) != 0) {
			fprintf(stderr, "watchdog enable register did not clear\n");
			if (imem_mapping != MAP_FAILED)
				munmap(imem_mapping, (size_t)page_size);
			munmap(wdt_mapping, (size_t)page_size);
			close(fd);
			return 7;
		}
	} else if (operation == OP_ARM_BOOTLOADER) {
		ticks = timeout_sec * WDT_RATE;
		write_reg(imem, imem_offset, RESTART_REASON_BOOTLOADER);
		write_reg(wdt, WDT_EN, 0);
		write_reg(wdt, WDT_RST, 1);
		write_reg(wdt, WDT_BARK_TIME, ticks);
		write_reg(wdt, WDT_BITE_TIME, ticks);
		write_reg(wdt, WDT_EN, 1);
		show_registers(wdt, "after");
		if ((read_reg(wdt, WDT_EN) & 1U) == 0 ||
		    read_reg(wdt, WDT_BITE_TIME) != ticks) {
			fprintf(stderr, "watchdog did not arm as requested\n");
			munmap(imem_mapping, (size_t)page_size);
			munmap(wdt_mapping, (size_t)page_size);
			close(fd);
			return 8;
		}
	}

	if (imem_mapping != MAP_FAILED)
		munmap(imem_mapping, (size_t)page_size);
	munmap(wdt_mapping, (size_t)page_size);
	close(fd);
	return 0;
}
