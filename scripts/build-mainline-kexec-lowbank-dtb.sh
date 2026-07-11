#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

DEFAULT_INPUT_DTB="$HOTDOG_ROOT/build/experiments/2026-07-09-090000-dtb-handoff-matrix/00-base-mainline617.dtb"
EXPECTED_DEFAULT_INPUT_SHA="44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49"
EXPECTED_DEFAULT_OUTPUT_SHA="e58d41e039e782f34b5cc1ec6406da833a2e30a54414058cd3e37a60fe10e19d"
INPUT_DTB="$DEFAULT_INPUT_DTB"
OUTDIR=""

usage() {
	cat <<'USAGE'
Usage: build-mainline-kexec-lowbank-dtb.sh [options]

Build the K1 low-bank mainline DTB used as the first DTB transform stage for
kexec testing. This is an offline-only helper: it copies the input DTB and
sets /memory reg from an open-ended placeholder to the validated low-bank RAM
window.

Options:
  --input-dtb FILE  Base mainline DTB. Default is the pinned handoff-matrix DTB.
  --outdir DIR      Output directory below build/experiments by default.
  -h, --help        Show this help.
USAGE
}

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--input-dtb)
			[ "$#" -ge 2 ] || die "--input-dtb requires a file"
			INPUT_DTB="$2"
			shift
			;;
		--outdir)
			[ "$#" -ge 2 ] || die "--outdir requires a directory"
			OUTDIR="$2"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
	shift
done

OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline617-kexec-lowbank-dtb}"
OUTPUT_DTB="$OUTDIR/sm8150-oneplus-hotdog-kexec-lowbank.dtb"
INPUT_MEMORY="0 80000000 0 0"
OUTPUT_MEMORY="0 80000000 0 3bb00000"
PIN_DEFAULT="no"

for command_name in awk diff dtc fdtget fdtput sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done

[ -s "$INPUT_DTB" ] || die "Missing input DTB: $INPUT_DTB"

input_sha="$(sha256sum "$INPUT_DTB" | awk '{ print $1 }')"
if [ "$INPUT_DTB" = "$DEFAULT_INPUT_DTB" ]; then
	PIN_DEFAULT="yes"
	[ "$input_sha" = "$EXPECTED_DEFAULT_INPUT_SHA" ] || {
		printf 'Pinned base DTB hash mismatch\n' >&2
		printf '  expected: %s\n' "$EXPECTED_DEFAULT_INPUT_SHA" >&2
		printf '  actual:   %s\n' "$input_sha" >&2
		exit 2
	}
fi

input_memory="$(fdtget -t x "$INPUT_DTB" /memory reg)" || die "Input DTB is missing /memory reg"
[ "$input_memory" = "$INPUT_MEMORY" ] || {
	printf 'Unexpected input /memory reg\n' >&2
	printf '  expected: %s\n' "$INPUT_MEMORY" >&2
	printf '  actual:   %s\n' "$input_memory" >&2
	exit 2
}

mkdir -p "$OUTDIR/semantic-diff"
cp "$INPUT_DTB" "$OUTPUT_DTB"
fdtput -t x "$OUTPUT_DTB" /memory reg 0 0x80000000 0 0x3bb00000

output_memory="$(fdtget -t x "$OUTPUT_DTB" /memory reg)" || die "Output DTB is missing /memory reg"
[ "$output_memory" = "$OUTPUT_MEMORY" ] || {
	printf 'Unexpected output /memory reg\n' >&2
	printf '  expected: %s\n' "$OUTPUT_MEMORY" >&2
	printf '  actual:   %s\n' "$output_memory" >&2
	exit 3
}

output_sha="$(sha256sum "$OUTPUT_DTB" | awk '{ print $1 }')"
if [ "$PIN_DEFAULT" = "yes" ]; then
	[ "$output_sha" = "$EXPECTED_DEFAULT_OUTPUT_SHA" ] || {
		printf 'Pinned lowbank output hash mismatch\n' >&2
		printf '  expected: %s\n' "$EXPECTED_DEFAULT_OUTPUT_SHA" >&2
		printf '  actual:   %s\n' "$output_sha" >&2
		exit 3
	}
fi

: > "$OUTDIR/dtc-warnings.txt"
dtc -I dtb -O dts -o "$OUTDIR/semantic-diff/input.dts" "$INPUT_DTB" 2>> "$OUTDIR/dtc-warnings.txt"
dtc -I dtb -O dts -o "$OUTDIR/semantic-diff/output.dts" "$OUTPUT_DTB" 2>> "$OUTDIR/dtc-warnings.txt"
cp "$OUTDIR/semantic-diff/output.dts" "$OUTDIR/verify.dts"
diff -u "$OUTDIR/semantic-diff/input.dts" "$OUTDIR/semantic-diff/output.dts" \
	> "$OUTDIR/semantic-diff/diff.patch" || true

{
	printf 'input_dtb=%s\n' "$INPUT_DTB"
	printf 'output_dtb=%s\n' "$OUTPUT_DTB"
	printf 'default_base_pinned=%s\n' "$PIN_DEFAULT"
	printf 'input_sha256=%s\n' "$input_sha"
	printf 'output_sha256=%s\n' "$output_sha"
	printf 'input_memory=%s\n' "$input_memory"
	printf 'output_memory=%s\n' "$output_memory"
	printf 'expected_input_memory=%s\n' "$INPUT_MEMORY"
	printf 'expected_output_memory=%s\n' "$OUTPUT_MEMORY"
} > "$OUTDIR/properties.txt"

sha256sum "$INPUT_DTB" "$OUTPUT_DTB" > "$OUTDIR/SHA256SUMS"

{
	printf '# Mainline Kexec Lowbank DTB\n\n'
	printf -- "- Input DTB: \`%s\`\n" "$INPUT_DTB"
	printf -- "- Output DTB: \`%s\`\n" "$OUTPUT_DTB"
	printf -- "- Default base pinned: \`%s\`\n" "$PIN_DEFAULT"
	printf -- "- Input SHA256: \`%s\`\n" "$input_sha"
	printf -- "- Output SHA256: \`%s\`\n" "$output_sha"
	printf -- "- Input \`/memory reg\`: \`%s\`\n" "$input_memory"
	printf -- "- Output \`/memory reg\`: \`%s\`\n" "$output_memory"
	printf '\n'
	printf 'This stage is offline-only and performs exactly one DTB mutation:\n\n'
	printf '```text\n'
	printf 'fdtput -t x OUTPUT_DTB /memory reg 0 0x80000000 0 0x3bb00000\n'
	printf '```\n'
} > "$OUTDIR/MANIFEST.md"

printf 'Output DTB: %s\n' "$OUTPUT_DTB"
cat "$OUTDIR/properties.txt"
cat "$OUTDIR/SHA256SUMS"
