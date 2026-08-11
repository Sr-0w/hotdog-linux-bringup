// SPDX-License-Identifier: MIT

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BITS_PER_LONG (sizeof(unsigned long) * 8)
#define BIT_WORD(bit) ((bit) / BITS_PER_LONG)
#define BIT_MASK(bit) (1UL << ((bit) % BITS_PER_LONG))

static int event_fd = -1;
static int effect_id = -1;

static int emit_effect(int value)
{
	struct input_event event = {
		.type = EV_FF,
		.code = effect_id,
		.value = value,
	};

	if (event_fd < 0 || effect_id < 0)
		return 0;

	return write(event_fd, &event, sizeof(event)) == sizeof(event) ? 0 : -1;
}

static void stop_effect(void)
{
	if (event_fd < 0 || effect_id < 0)
		return;

	emit_effect(0);
	ioctl(event_fd, EVIOCRMFF, effect_id);
	effect_id = -1;
}

static void handle_signal(int signal_number)
{
	stop_effect();
	_exit(128 + signal_number);
}

static unsigned int parse_number(const char *value, const char *name,
				 unsigned int minimum, unsigned int maximum)
{
	char *end = NULL;
	unsigned long number;

	errno = 0;
	number = strtoul(value, &end, 10);
	if (errno || !end || *end || number < minimum || number > maximum) {
		fprintf(stderr, "%s must be between %u and %u\n",
			name, minimum, maximum);
		exit(EXIT_FAILURE);
	}

	return number;
}

int main(int argc, char **argv)
{
	unsigned long ff_bits[BIT_WORD(FF_MAX) + 1] = { 0 };
	unsigned long event_bits[BIT_WORD(EV_MAX) + 1] = { 0 };
	unsigned int strength;
	unsigned int duration;
	struct ff_effect effect = {
		.type = FF_RUMBLE,
		.id = -1,
	};
	struct sigaction action = {
		.sa_handler = handle_signal,
	};

	if (argc != 4) {
		fprintf(stderr,
			"Usage: %s /dev/input/eventN strength-percent duration-ms\n",
			argv[0]);
		return EXIT_FAILURE;
	}

	strength = parse_number(argv[2], "strength", 1, 100);
	duration = parse_number(argv[3], "duration", 10, 1000);

	event_fd = open(argv[1], O_RDWR | O_CLOEXEC);
	if (event_fd < 0) {
		fprintf(stderr, "cannot open %s: %s\n", argv[1], strerror(errno));
		return EXIT_FAILURE;
	}

	if (ioctl(event_fd, EVIOCGBIT(0, sizeof(event_bits)), event_bits) < 0 ||
	    !(event_bits[BIT_WORD(EV_FF)] & BIT_MASK(EV_FF))) {
		fprintf(stderr, "%s does not expose EV_FF\n", argv[1]);
		return EXIT_FAILURE;
	}
	if (ioctl(event_fd, EVIOCGBIT(EV_FF, sizeof(ff_bits)), ff_bits) < 0 ||
	    !(ff_bits[BIT_WORD(FF_RUMBLE)] & BIT_MASK(FF_RUMBLE))) {
		fprintf(stderr, "%s does not expose FF_RUMBLE\n", argv[1]);
		return EXIT_FAILURE;
	}

	sigemptyset(&action.sa_mask);
	sigaction(SIGINT, &action, NULL);
	sigaction(SIGTERM, &action, NULL);
	atexit(stop_effect);

	effect.replay.length = duration;
	effect.u.rumble.strong_magnitude =
		(uint16_t)(((uint64_t)strength * UINT16_MAX) / 100);
	if (ioctl(event_fd, EVIOCSFF, &effect) < 0) {
		fprintf(stderr, "cannot upload rumble effect: %s\n", strerror(errno));
		return EXIT_FAILURE;
	}
	effect_id = effect.id;

	printf("pulse: device=%s strength=%u%% duration=%ums effect=%d\n",
	       argv[1], strength, duration, effect_id);
	if (emit_effect(1) < 0) {
		fprintf(stderr, "cannot start rumble effect: %s\n", strerror(errno));
		return EXIT_FAILURE;
	}

	usleep((duration + 50U) * 1000U);
	stop_effect();
	return EXIT_SUCCESS;
}
