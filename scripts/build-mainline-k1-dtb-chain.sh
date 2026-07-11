#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

EXPECTED_BASE_SHA="44052506301f7fcad9725c77a98323ec283adf1159b7bee941e7ed2ac3447b49"
BASE_DTB=""
SOURCE_TREE=""
OUTDIR=""
JOBS="${JOBS:-$(nproc 2>/dev/null || printf '1\n')}"
ALLOW_UNPINNED_BASE=0

usage() {
	cat <<'USAGE'
Usage: build-mainline-k1-dtb-chain.sh [options]

Run the complete offline K1 DTB transform chain:
  00 source rebuild
  01 lowbank
  02 firmware-gap
  03 UFS/QUP Apps SMMU bypass
  04 no UFS ICE
  05 pmOS/DWC3 Apps SMMU bypass

Options:
  --base-dtb FILE  Use an existing base DTB instead of rebuilding it.
  --allow-unpinned-base
                   Permit an explicitly provided base DTB whose SHA256 differs
                   from the validated K1 base. Intended only for experiments.
  --source-tree D  Kernel git checkout used by the source rebuild.
  --jobs N         Parallel jobs for the source rebuild. Default: CPU count.
  --outdir DIR     Output directory below build/experiments by default.
  -h, --help       Show this help.
USAGE
}

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--base-dtb)
			[ "$#" -ge 2 ] || die "--base-dtb requires a file"
			BASE_DTB="$2"
			shift
			;;
		--allow-unpinned-base)
			ALLOW_UNPINNED_BASE=1
			;;
		--outdir)
			[ "$#" -ge 2 ] || die "--outdir requires a directory"
			OUTDIR="$2"
			shift
			;;
		--source-tree)
			[ "$#" -ge 2 ] || die "--source-tree requires a directory"
			SOURCE_TREE="$2"
			shift
			;;
		--jobs)
			[ "$#" -ge 2 ] || die "--jobs requires a value"
			JOBS="$2"
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

OUTDIR="${OUTDIR:-$HOTDOG_ROOT/build/experiments/$(date +%F-%H%M%S)-mainline617-k1-dtb-chain}"
OUTDIR="$(readlink -m "$OUTDIR")"

case "$JOBS" in
	''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be a positive integer"
[ -z "$BASE_DTB" ] || [ -z "$SOURCE_TREE" ] || die "--source-tree cannot be combined with --base-dtb"
[ "$ALLOW_UNPINNED_BASE" -eq 0 ] || [ -n "$BASE_DTB" ] || die "--allow-unpinned-base requires --base-dtb"

for command_name in awk cmp cp mkdir readlink sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || {
		printf 'Missing command: %s\n' "$command_name" >&2
		exit 127
	}
done

mkdir -p "$OUTDIR"

base_origin="provided"
if [ -z "$BASE_DTB" ]; then
	base_origin="source-rebuild"
	base_dir="$OUTDIR/00-source-base"
	base_args=(--outdir "$base_dir" --jobs "$JOBS")
	if [ -n "$SOURCE_TREE" ]; then
		base_args+=(--source-tree "$SOURCE_TREE")
	fi
	"$HOTDOG_ROOT/scripts/build-mainline-k1-base-dtb.sh" "${base_args[@]}"
	BASE_DTB="$base_dir/00-base-mainline617.dtb"
fi

[ -s "$BASE_DTB" ] || die "Missing base DTB: $BASE_DTB"

base_sha="$(sha256sum "$BASE_DTB" | awk '{ print $1 }')"
pin_base="no"
if [ "$base_sha" = "$EXPECTED_BASE_SHA" ]; then
	pin_base="yes"
fi
if [ "$pin_base" != "yes" ]; then
	if [ "$base_origin" != "provided" ] || [ "$ALLOW_UNPINNED_BASE" -ne 1 ]; then
		printf 'K1 base DTB hash mismatch\n' >&2
		printf '  expected: %s\n' "$EXPECTED_BASE_SHA" >&2
		printf '  actual:   %s\n' "$base_sha" >&2
		printf 'Use --allow-unpinned-base only for an intentional experimental transform.\n' >&2
		exit 3
	fi
	printf '[k1-dtb-chain] WARNING: accepting explicitly allowed unpinned base %s\n' "$base_sha" >&2
fi

run_stage() {
	local label="$1"
	local builder="$2"
	local outdir="$3"
	local input="$4"
	local output="$5"

	printf '[k1-dtb-chain] %s\n' "$label"
	"$builder" --input-dtb "$input" --outdir "$outdir"
	[ -s "$output" ] || die "Stage did not produce expected DTB: $output"
}

check_hash() {
	local label="$1"
	local path="$2"
	local expected="$3"
	local actual

	actual="$(sha256sum "$path" | awk '{ print $1 }')"
	if [ "$actual" != "$expected" ]; then
		printf '%s hash mismatch\n' "$label" >&2
		printf '  expected: %s\n' "$expected" >&2
		printf '  actual:   %s\n' "$actual" >&2
		exit 3
	fi
	printf '%s=%s\n' "$label" "$actual" >> "$OUTDIR/properties.txt"
}

lowbank_dir="$OUTDIR/01-lowbank"
firmware_gap_dir="$OUTDIR/02-firmware-gap"
smmu_dir="$OUTDIR/03-ufs-qup-smmu-bypass"
no_ice_dir="$OUTDIR/04-no-ice"
pmos_dir="$OUTDIR/05-pmos-dwc3"

lowbank_dtb="$lowbank_dir/sm8150-oneplus-hotdog-kexec-lowbank.dtb"
firmware_gap_dtb="$firmware_gap_dir/sm8150-oneplus-hotdog-kexec-lowbank-firmware-gap.dtb"
smmu_dtb="$smmu_dir/sm8150-oneplus-hotdog-kexec-lowbank-ufs-smmu-bypass.dtb"
no_ice_dtb="$no_ice_dir/sm8150-oneplus-hotdog-kexec-lowbank-ufs-smmu-bypass-no-ice.dtb"
pmos_dtb="$pmos_dir/sm8150-oneplus-hotdog-mainline-pmos-boot.dtb"
final_dtb="$OUTDIR/final.dtb"

: > "$OUTDIR/properties.txt"
{
	printf 'base_dtb=%s\n' "$BASE_DTB"
	printf 'base_origin=%s\n' "$base_origin"
	printf 'base_sha256=%s\n' "$base_sha"
	printf 'base_pinned=%s\n' "$pin_base"
	printf 'allow_unpinned_base=%s\n' "$ALLOW_UNPINNED_BASE"
	printf 'outdir=%s\n' "$OUTDIR"
} >> "$OUTDIR/properties.txt"

run_stage "01 lowbank" "$HOTDOG_ROOT/scripts/build-mainline-kexec-lowbank-dtb.sh" \
	"$lowbank_dir" "$BASE_DTB" "$lowbank_dtb"
run_stage "02 firmware-gap" "$HOTDOG_ROOT/scripts/build-mainline-lowbank-firmware-gap-dtb.sh" \
	"$firmware_gap_dir" "$lowbank_dtb" "$firmware_gap_dtb"
run_stage "03 UFS/QUP Apps SMMU bypass" "$HOTDOG_ROOT/scripts/build-mainline-ufs-smmu-bypass-dtb.sh" \
	"$smmu_dir" "$firmware_gap_dtb" "$smmu_dtb"
run_stage "04 no UFS ICE" "$HOTDOG_ROOT/scripts/build-mainline-ufs-no-ice-dtb.sh" \
	"$no_ice_dir" "$smmu_dtb" "$no_ice_dtb"
run_stage "05 pmOS/DWC3 Apps SMMU bypass" "$HOTDOG_ROOT/scripts/build-mainline-pmos-boot-dtb.sh" \
	"$pmos_dir" "$no_ice_dtb" "$pmos_dtb"

cp "$pmos_dtb" "$final_dtb"
cmp -s "$pmos_dtb" "$final_dtb" || die "final.dtb differs from stage 05 output"

if [ "$pin_base" = "yes" ]; then
	check_hash stage_01_lowbank_sha256 "$lowbank_dtb" \
		e58d41e039e782f34b5cc1ec6406da833a2e30a54414058cd3e37a60fe10e19d
	check_hash stage_02_firmware_gap_sha256 "$firmware_gap_dtb" \
		d9d31d6f50ff14bbd8d2963061388ee6b9a722a7d08394f2fec6572dcfb77346
	check_hash stage_03_ufs_qup_smmu_bypass_sha256 "$smmu_dtb" \
		d8cfc758634d087f87c37be38b14a9679464d48131b814be4383c6e25e44431d
	check_hash stage_04_no_ice_sha256 "$no_ice_dtb" \
		7334f79e38cb3168bf6961283b023893b6c71e477aaf42ec97646b21992d0bf0
	check_hash stage_05_pmos_dwc3_sha256 "$pmos_dtb" \
		cf63ae7f686bc76b912520f54e14c589b4c23c833069e45ba9097157a0665440
fi

final_sha="$(sha256sum "$final_dtb" | awk '{ print $1 }')"
printf 'final_sha256=%s\n' "$final_sha" >> "$OUTDIR/properties.txt"
printf 'final_dtb=%s\n' "$final_dtb" >> "$OUTDIR/properties.txt"

sha256sum \
	"$BASE_DTB" \
	"$lowbank_dtb" \
	"$firmware_gap_dtb" \
	"$smmu_dtb" \
	"$no_ice_dtb" \
	"$pmos_dtb" \
	"$final_dtb" \
	> "$OUTDIR/SHA256SUMS"

{
	printf '# Mainline K1 DTB Chain\n\n'
	printf -- "- Base DTB: \`%s\`\n" "$BASE_DTB"
	printf -- "- Base origin: \`%s\`\n" "$base_origin"
	printf -- "- Base SHA256: \`%s\`\n" "$base_sha"
	printf -- "- Base pinned: \`%s\`\n" "$pin_base"
	printf -- "- Unpinned base explicitly allowed: \`%s\`\n" "$ALLOW_UNPINNED_BASE"
	printf -- "- Final DTB: \`%s\`\n" "$final_dtb"
	printf -- "- Final SHA256: \`%s\`\n\n" "$final_sha"
	printf '## Stages\n\n'
	if [ "$base_origin" = "source-rebuild" ]; then
		printf "0. \`00-source-base\`: rebuilds the exact K1 base DTB from pinned source and config.\n"
	else
		printf "0. Uses the caller-provided base DTB after recording its hash.\n"
	fi
	printf "1. \`01-lowbank\`: constrains \`/memory reg\` to the K1 low-bank window.\n"
	printf "2. \`02-firmware-gap\`: adds the firmware-owned \`hotdog-removed-gap@89d00000\` \`no-map\` reservation.\n"
	printf "3. \`03-ufs-qup-smmu-bypass\`: temporarily removes Apps SMMU links from UFS and QUP.\n"
	printf "4. \`04-no-ice\`: temporarily removes the UFS \`qcom,ice\` phandle.\n"
	printf "5. \`05-pmos-dwc3\`: temporarily removes the DWC3 Apps SMMU link for pmOS USB gadget bring-up.\n\n"
	printf 'The SMMU and ICE removals are bring-up hacks. They must not be treated as upstreamable fixes.\n'
} > "$OUTDIR/MANIFEST.md"

printf 'Final DTB: %s\n' "$final_dtb"
cat "$OUTDIR/properties.txt"
cat "$OUTDIR/SHA256SUMS"
