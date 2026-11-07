/* Host-side check of the 6.12 backport's float-voltage decision.
 *
 * This is not a kernel build and not a hardware test. It executes the same
 * comparisons and integer division as smb2_probe(), and it checks that the
 * patched driver source still contains those expressions.
 *
 * Absent optional battery properties are -EINVAL in v6.12.116.
 * power_supply_battery_info_has_prop() treats these two voltages as present
 * when the stored value is >= 0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SMB2_FLOAT_VOLTAGE_MIN_UV 3487500
#define SMB2_FLOAT_VOLTAGE_MAX_UV 4920000
#define SMB2_FLOAT_VOLTAGE_STEP_UV 7500
#define ABSENT (-22) /* -EINVAL on Linux */

enum action {
	ACT_SKIP = 0,
	ACT_REJECT = 1,
	ACT_PROGRAM = 2,
};

static int has_prop(int value)
{
	return value >= 0;
}

static enum action select_float(int constant_charge_uv, int design_uv,
				unsigned int *selector)
{
	int float_voltage_uv;

	if (has_prop(constant_charge_uv))
		float_voltage_uv = constant_charge_uv;
	else if (has_prop(design_uv))
		float_voltage_uv = design_uv;
	else
		return ACT_SKIP;

	if (float_voltage_uv < SMB2_FLOAT_VOLTAGE_MIN_UV ||
	    float_voltage_uv > SMB2_FLOAT_VOLTAGE_MAX_UV)
		return ACT_REJECT;

	*selector = (unsigned int)((float_voltage_uv - SMB2_FLOAT_VOLTAGE_MIN_UV) /
				   SMB2_FLOAT_VOLTAGE_STEP_UV);
	return ACT_PROGRAM;
}

static int failures;

static void expect_skip(const char *name, int cc, int design)
{
	unsigned int selector = 0xdeadbeef;

	if (select_float(cc, design, &selector) != ACT_SKIP ||
	    selector != 0xdeadbeef) {
		fprintf(stderr, "FAIL %s: expected skip\n", name);
		failures++;
	}
}

static void expect_reject(const char *name, int cc, int design)
{
	unsigned int selector = 0xdeadbeef;

	if (select_float(cc, design, &selector) != ACT_REJECT ||
	    selector != 0xdeadbeef) {
		fprintf(stderr, "FAIL %s: expected reject\n", name);
		failures++;
	}
}

static void expect_program(const char *name, int cc, int design,
			   unsigned int want)
{
	unsigned int selector = 0xdeadbeef;
	enum action action = select_float(cc, design, &selector);

	if (action != ACT_PROGRAM || selector != want) {
		fprintf(stderr, "FAIL %s: action %d selector %u want %u\n",
			name, action, selector, want);
		failures++;
	}
	if (want > 0xff) {
		fprintf(stderr, "FAIL %s: selector %u exceeds 8-bit mask\n",
			name, want);
		failures++;
	}
}

static char *read_file(const char *path)
{
	FILE *file = fopen(path, "r");
	long length;
	char *buf;

	if (!file) {
		perror(path);
		exit(2);
	}
	if (fseek(file, 0, SEEK_END) != 0 || (length = ftell(file)) < 0) {
		perror("ftell");
		exit(2);
	}
	rewind(file);
	buf = malloc((size_t)length + 1);
	if (!buf || fread(buf, 1, (size_t)length, file) != (size_t)length) {
		perror("fread");
		exit(2);
	}
	buf[length] = '\0';
	fclose(file);
	return buf;
}

static void require_text(const char *source, const char *needle)
{
	if (!strstr(source, needle)) {
		fprintf(stderr, "FAIL source missing: %s\n", needle);
		failures++;
	}
}

static void check_source(const char *path)
{
	char *source = read_file(path);
	const char *probe;
	const char *read_enable;
	const char *init_hw;
	const char *remove_action;
	const char *range;
	const char *division;
	const char *plus_one;

	require_text(source, "#define SMB2_FLOAT_VOLTAGE_MIN_UV\t\t\t3487500");
	require_text(source, "#define SMB2_FLOAT_VOLTAGE_MAX_UV\t\t\t4920000");
	require_text(source, "#define SMB2_FLOAT_VOLTAGE_STEP_UV\t\t\t7500");
	require_text(source,
		     "float_voltage_uv < SMB2_FLOAT_VOLTAGE_MIN_UV ||");
	require_text(source,
		     "float_voltage_uv > SMB2_FLOAT_VOLTAGE_MAX_UV");
	require_text(source,
		     "(float_voltage_uv - SMB2_FLOAT_VOLTAGE_MIN_UV) /");
	require_text(source, "SMB2_FLOAT_VOLTAGE_STEP_UV;");
	require_text(source, "POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE_MAX");
	require_text(source, "POWER_SUPPLY_PROP_VOLTAGE_MAX_DESIGN");
	require_text(source, "goto skip_float_voltage;");
	require_text(source, "smb2_restore_charge_enable");
	require_text(source, "dev_pm_set_wake_irq(chip->dev, chip->cable_irq);");

	probe = strstr(source, "static int smb2_probe(");
	if (!probe) {
		fprintf(stderr, "FAIL smb2_probe not found\n");
		failures++;
		free(source);
		return;
	}
	read_enable = strstr(probe, "CHARGING_ENABLE_CMD");
	init_hw = strstr(probe, "smb2_init_hw(chip)");
	remove_action = strstr(probe, "devm_remove_action(");
	range = strstr(probe, "float_voltage_uv < SMB2_FLOAT_VOLTAGE_MIN_UV");
	division = strstr(probe, "(float_voltage_uv - SMB2_FLOAT_VOLTAGE_MIN_UV)");
	plus_one = strstr(probe, "+ 1");
	if (!read_enable || !init_hw || !remove_action || !range || !division ||
	    !(read_enable < init_hw) || !(range < division) ||
	    !(init_hw < range) || !(division < remove_action)) {
		fprintf(stderr, "FAIL probe ordering does not match upstream\n");
		failures++;
	}
	if (plus_one) {
		fprintf(stderr, "FAIL selector off-by-one is still in smb2_probe\n");
		failures++;
	}
	free(source);
}

int main(int argc, char **argv)
{
	const int min_uv = SMB2_FLOAT_VOLTAGE_MIN_UV;
	const int max_uv = SMB2_FLOAT_VOLTAGE_MAX_UV;
	const int step = SMB2_FLOAT_VOLTAGE_STEP_UV;

	if (min_uv + 191 * step != max_uv) {
		fprintf(stderr, "FAIL range is not 191 exact steps\n");
		return 1;
	}

	expect_skip("neither property", ABSENT, ABSENT);
	expect_skip("negative design only", ABSENT, -1);
	expect_reject("zero is present but below range", ABSENT, 0);
	expect_reject("one microvolt below minimum", ABSENT, min_uv - 1);
	expect_program("minimum encodes selector 0", ABSENT, min_uv, 0);
	expect_program("below the next step truncates to 0", ABSENT,
		       min_uv + step - 1, 0);
	expect_program("one step encodes selector 1", ABSENT, min_uv + step, 1);
	expect_program("4350000 uV is an exact selector", ABSENT, 4350000, 115);
	expect_program("4400000 uV truncates and does not add one",
		       4400000, 4350000, 121);
	expect_program("constant-charge wins over a different design",
		       min_uv, max_uv, 0);
	expect_program("maximum encodes selector 191", max_uv, ABSENT, 191);
	expect_program("one below maximum truncates to 190", ABSENT, max_uv - 1,
		       190);
	expect_program("aligned step below maximum", ABSENT, max_uv - step, 190);
	expect_reject("one microvolt above maximum", max_uv + 1, ABSENT);
	expect_reject("INT_MAX constant-charge", 2147483647, ABSENT);
	expect_skip("INT_MIN design is absent", ABSENT, -2147483647 - 1);
	expect_skip("both negative", -2147483647 - 1, ABSENT);
	expect_program("negative constant-charge falls back to design",
		       -2147483647 - 1, 4350000, 115);

	/* Old off-by-one formula would program 4350000 uV as 116. */
	if (((4350000 - 3487500) / 7500 + 1) != 116) {
		fprintf(stderr, "FAIL old formula fixture changed\n");
		failures++;
	}

	if (argc == 2)
		check_source(argv[1]);
	else {
		fprintf(stderr, "usage: %s path/to/qcom_pmi8998_charger.c\n",
			argv[0]);
		return 2;
	}

	if (failures) {
		fprintf(stderr, "%d failure(s)\n", failures);
		return 1;
	}
	printf("float-voltage range test: pass\n");
	return 0;
}
