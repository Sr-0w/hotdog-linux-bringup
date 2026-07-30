#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/reboot.h>
#include <linux/watchdog.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef DEVMEM_PATH
#define DEVMEM_PATH "/dev/mem"
#endif

#ifndef WATCHDOG_PATH
#define WATCHDOG_PATH "/dev/watchdog0"
#endif

#define SUPERVISOR_MARKER "HOTDOG_RESCUE_SUPERVISOR_V1"
#define APSS_WDT_PHYS 0x17c10000UL
#define IMEM_RESTART_REASON_PHYS 0x146bf65cUL
#define RESTART_REASON_BOOTLOADER 0x77665500U
#define RESTART_REASON_NORMAL 0x77665501U
#define WDT_RATE 32764U
#define WDT_TIMEOUT_SEC 32U
#define WDT_DEADLINE_TIMEOUT_SEC 2U
#define WDT_RST 0x04
#define WDT_EN 0x08
#define WDT_BARK_TIME 0x10
#define WDT_BITE_TIME 0x14
#define MIN_DEADLINE_SEC 10U
#define MAX_DEADLINE_SEC 86400U

struct hardware {
	long page_size;
	int devmem_fd;
	int watchdog_fd;
	void *wdt_mapping;
	void *imem_mapping;
	volatile uint8_t *wdt;
	volatile uint8_t *imem;
	size_t imem_offset;
	bool watchdog_device;
	bool armed;
};

static void usage(const char *name)
{
	fprintf(stderr,
		"usage: %s --deadline SECONDS --success-file PATH\n"
		"       %s --self-test\n",
		name, name);
}

static bool parse_deadline(const char *value, uint32_t *seconds)
{
	char *end = NULL;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(value, &end, 10);
	if (errno != 0 || end == value || *end != '\0' ||
	    parsed < MIN_DEADLINE_SEC || parsed > MAX_DEADLINE_SEC)
		return false;

	*seconds = (uint32_t)parsed;
	return true;
}

static uint32_t read_reg(volatile uint8_t *base, size_t offset)
{
	return *(volatile uint32_t *)(base + offset);
}

static void write_reg(volatile uint8_t *base, size_t offset, uint32_t value)
{
	*(volatile uint32_t *)(base + offset) = value;
	__sync_synchronize();
}

static void hardware_close(struct hardware *hardware)
{
	if (hardware->watchdog_fd >= 0)
		close(hardware->watchdog_fd);
	if (hardware->imem_mapping != MAP_FAILED)
		munmap(hardware->imem_mapping, (size_t)hardware->page_size);
	if (hardware->wdt_mapping != MAP_FAILED)
		munmap(hardware->wdt_mapping, (size_t)hardware->page_size);
	if (hardware->devmem_fd >= 0)
		close(hardware->devmem_fd);
}

static void watchdog_device_stop(int fd)
{
	int options = WDIOS_DISABLECARD;
	const char magic_close = 'V';

	(void)ioctl(fd, WDIOC_SETOPTIONS, &options);
	(void)write(fd, &magic_close, sizeof(magic_close));
}

static bool watchdog_device_open(struct hardware *hardware)
{
	int timeout = WDT_TIMEOUT_SEC;

	hardware->watchdog_fd = open(WATCHDOG_PATH, O_WRONLY | O_CLOEXEC);
	if (hardware->watchdog_fd < 0) {
		fprintf(stderr, "open %s: %s\n", WATCHDOG_PATH,
			strerror(errno));
		return false;
	}
	if (ioctl(hardware->watchdog_fd, WDIOC_SETTIMEOUT, &timeout) < 0) {
		fprintf(stderr, "WDIOC_SETTIMEOUT on %s: %s\n", WATCHDOG_PATH,
			strerror(errno));
		watchdog_device_stop(hardware->watchdog_fd);
		close(hardware->watchdog_fd);
		hardware->watchdog_fd = -1;
		return false;
	}
	if (ioctl(hardware->watchdog_fd, WDIOC_KEEPALIVE, 0) < 0) {
		fprintf(stderr, "WDIOC_KEEPALIVE on %s: %s\n", WATCHDOG_PATH,
			strerror(errno));
		watchdog_device_stop(hardware->watchdog_fd);
		close(hardware->watchdog_fd);
		hardware->watchdog_fd = -1;
		return false;
	}

	hardware->watchdog_device = true;
	hardware->armed = true;
	fprintf(stderr, "armed %s with timeout %d seconds\n",
		WATCHDOG_PATH, timeout);
	return true;
}

static bool mmio_hardware_open(struct hardware *hardware)
{
	unsigned long imem_page;

	hardware->page_size = sysconf(_SC_PAGESIZE);
	if (hardware->page_size <= 0 ||
	    APSS_WDT_PHYS % (unsigned long)hardware->page_size != 0) {
		fprintf(stderr, "unsupported page size: %ld\n",
			hardware->page_size);
		return false;
	}

	imem_page = IMEM_RESTART_REASON_PHYS &
		~((unsigned long)hardware->page_size - 1);
	hardware->imem_offset =
		(size_t)(IMEM_RESTART_REASON_PHYS - imem_page);
	hardware->devmem_fd = open(DEVMEM_PATH, O_RDWR | O_SYNC);
	if (hardware->devmem_fd < 0) {
		fprintf(stderr, "open %s: %s\n", DEVMEM_PATH,
			strerror(errno));
		return false;
	}

	hardware->wdt_mapping =
		mmap(NULL, (size_t)hardware->page_size,
		     PROT_READ | PROT_WRITE, MAP_SHARED, hardware->devmem_fd,
		     (off_t)APSS_WDT_PHYS);
	if (hardware->wdt_mapping == MAP_FAILED) {
		fprintf(stderr, "mmap watchdog 0x%lx: %s\n", APSS_WDT_PHYS,
			strerror(errno));
		hardware_close(hardware);
		return false;
	}

	hardware->imem_mapping =
		mmap(NULL, (size_t)hardware->page_size,
		     PROT_READ | PROT_WRITE, MAP_SHARED, hardware->devmem_fd,
		     (off_t)imem_page);
	if (hardware->imem_mapping == MAP_FAILED) {
		fprintf(stderr,
			"mmap optional restart reason 0x%lx: %s; "
			"continuing with watchdog only\n",
			imem_page, strerror(errno));
		hardware->imem = NULL;
	} else {
		hardware->imem = hardware->imem_mapping;
	}

	hardware->wdt = hardware->wdt_mapping;
	return true;
}

static bool hardware_open(struct hardware *hardware)
{
	memset(hardware, 0, sizeof(*hardware));
	hardware->devmem_fd = -1;
	hardware->watchdog_fd = -1;
	hardware->wdt_mapping = MAP_FAILED;
	hardware->imem_mapping = MAP_FAILED;

	if (watchdog_device_open(hardware))
		return true;
	return mmio_hardware_open(hardware);
}

static bool hardware_arm_mmio(struct hardware *hardware)
{
	const uint32_t ticks = WDT_TIMEOUT_SEC * WDT_RATE;

	if (hardware->imem)
		write_reg(hardware->imem, hardware->imem_offset,
			  RESTART_REASON_BOOTLOADER);
	write_reg(hardware->wdt, WDT_EN, 0);
	write_reg(hardware->wdt, WDT_RST, 1);
	write_reg(hardware->wdt, WDT_BARK_TIME, ticks);
	write_reg(hardware->wdt, WDT_BITE_TIME, ticks);
	write_reg(hardware->wdt, WDT_EN, 1);
	if ((read_reg(hardware->wdt, WDT_EN) & 1U) == 0 ||
	    read_reg(hardware->wdt, WDT_BITE_TIME) != ticks) {
		fprintf(stderr, "APSS watchdog did not arm as requested\n");
		return false;
	}

	hardware->armed = true;
	return true;
}

static void hardware_kick(struct hardware *hardware)
{
	if (!hardware->armed)
		return;
	if (hardware->watchdog_device)
		(void)ioctl(hardware->watchdog_fd, WDIOC_KEEPALIVE, 0);
	else
		write_reg(hardware->wdt, WDT_RST, 1);
}

static void hardware_disarm(struct hardware *hardware)
{
	if (!hardware->armed)
		return;

	if (hardware->watchdog_device) {
		watchdog_device_stop(hardware->watchdog_fd);
	} else {
		write_reg(hardware->wdt, WDT_EN, 0);
		if (hardware->imem)
			write_reg(hardware->imem, hardware->imem_offset,
				  RESTART_REASON_NORMAL);
	}
	hardware->armed = false;
}

static void hardware_prepare_deadline(struct hardware *hardware)
{
	const uint32_t ticks = WDT_DEADLINE_TIMEOUT_SEC * WDT_RATE;

	if (!hardware->armed)
		return;
	if (hardware->watchdog_device) {
		int timeout = WDT_DEADLINE_TIMEOUT_SEC;

		if (ioctl(hardware->watchdog_fd, WDIOC_SETTIMEOUT,
			  &timeout) < 0)
			fprintf(stderr, "deadline WDIOC_SETTIMEOUT: %s\n",
				strerror(errno));
		(void)ioctl(hardware->watchdog_fd, WDIOC_KEEPALIVE, 0);
		return;
	}

	if (hardware->imem)
		write_reg(hardware->imem, hardware->imem_offset,
			  RESTART_REASON_BOOTLOADER);
	write_reg(hardware->wdt, WDT_EN, 0);
	write_reg(hardware->wdt, WDT_RST, 1);
	write_reg(hardware->wdt, WDT_BARK_TIME, ticks);
	write_reg(hardware->wdt, WDT_BITE_TIME, ticks);
	write_reg(hardware->wdt, WDT_EN, 1);
}

static int sleep_one_second(void)
{
	struct timespec remaining = {
		.tv_sec = 1,
		.tv_nsec = 0,
	};

	while (nanosleep(&remaining, &remaining) < 0) {
		if (errno != EINTR)
			return -1;
	}
	return 0;
}

static int self_test(void)
{
	struct timespec before;
	struct timespec after;

	if (clock_gettime(CLOCK_MONOTONIC, &before) < 0)
		return 1;
	if (sleep_one_second() < 0)
		return 1;
	if (clock_gettime(CLOCK_MONOTONIC, &after) < 0)
		return 1;
	if (after.tv_sec < before.tv_sec + 1)
		return 1;

	printf("%s SELF_TEST_OK\n", SUPERVISOR_MARKER);
	return 0;
}

int main(int argc, char **argv)
{
	struct hardware hardware;
	const char *success_file = NULL;
	uint32_t deadline_sec = 0;
	uint32_t elapsed;
	bool hardware_available;
	long rc;
	int i;

	if (argc == 2 && strcmp(argv[1], "--self-test") == 0)
		return self_test();

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--deadline") == 0 && i + 1 < argc) {
			if (!parse_deadline(argv[++i], &deadline_sec)) {
				fprintf(stderr, "invalid deadline: %s\n", argv[i]);
				return 2;
			}
		} else if (strcmp(argv[i], "--success-file") == 0 &&
			   i + 1 < argc) {
			success_file = argv[++i];
		} else {
			usage(argv[0]);
			return 2;
		}
	}
	if (deadline_sec == 0 || success_file == NULL ||
	    success_file[0] != '/') {
		usage(argv[0]);
		return 2;
	}

	printf("%s deadline=%" PRIu32 " success=%s\n", SUPERVISOR_MARKER,
	       deadline_sec, success_file);
	hardware_available = hardware_open(&hardware);
	if (hardware_available && !hardware.watchdog_device &&
	    !hardware_arm_mmio(&hardware)) {
		hardware_close(&hardware);
		hardware_available = false;
	}

	for (elapsed = 0; elapsed < deadline_sec; elapsed++) {
		if (access(success_file, F_OK) == 0) {
			if (hardware_available) {
				hardware_disarm(&hardware);
				hardware_close(&hardware);
			}
			printf("%s SUCCESS\n", SUPERVISOR_MARKER);
			return 0;
		}
		if (hardware_available)
			hardware_kick(&hardware);
		if (sleep_one_second() < 0) {
			fprintf(stderr, "nanosleep: %s\n", strerror(errno));
			break;
		}
	}

	fprintf(stderr, "%s DEADLINE_RESTART2\n", SUPERVISOR_MARKER);
	if (hardware_available)
		hardware_prepare_deadline(&hardware);
	rc = syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		     LINUX_REBOOT_CMD_RESTART2, "bootloader");
	fprintf(stderr, "reboot(bootloader) returned: %s\n",
		rc < 0 ? strerror(errno) : "unexpected success");

	if (hardware_available) {
		/*
		 * Keep the watchdog armed and stop kicking it. If RESTART2 is
		 * unavailable, it normally bites after the requested two seconds.
		 * A driver that rejects the shorter timeout retains the 32-second
		 * armed fallback.
		 */
		hardware_close(&hardware);
	}
	return 1;
}
