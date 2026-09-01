#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
	cat <<'EOF'
Usage: prepare-hotdog-stock-edl-plan.sh SOURCE_EXTRACT OUTPUT_PLAN

Create an isolated plan whose payloads are read-only links to an extracted
hotdog OPS tree, copy its XML files, and remove every program operation targeting
persist. The source tree is never modified. This script does not access a phone.
EOF
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$#" -eq 2 ] || { usage >&2; exit 2; }
source_dir="$(realpath "$1")"
output_dir="$2"

[ -d "$source_dir" ] || die "source extract is not a directory: $source_dir"
[ ! -e "$output_dir" ] || die "output already exists: $output_dir"
command -v rg >/dev/null 2>&1 || die "missing rg"
command -v sha256sum >/dev/null 2>&1 || die "missing sha256sum"

for lun in 0 1 2 3 4 5; do
	[ -s "$source_dir/rawprogram${lun}.xml" ] || die "missing rawprogram${lun}.xml"
	[ -s "$source_dir/patch${lun}.xml" ] || die "missing patch${lun}.xml"
done
[ -s "$source_dir/prog_firehose_ddr.elf" ] || die "missing prog_firehose_ddr.elf"

mkdir -p "$output_dir"
# Keep multi-gigabyte payloads in the verified extraction. XML files are copied
# below before editing, so no plan operation can modify the source XML.
while IFS= read -r -d '' source_file; do
	ln -s "$source_file" "$output_dir/$(basename "$source_file")"
done < <(find "$source_dir" -mindepth 1 -maxdepth 1 -type f -print0)

for source_xml in "$source_dir"/rawprogram*.xml "$source_dir"/patch*.xml; do
	name="$(basename "$source_xml")"
	cp --remove-destination "$source_xml" "$output_dir/$name"
done

# Patch XML contains both on-device DISK operations and local GPT-file
# operations. Detach the local GPT payloads so a flasher cannot patch through a
# symlink into the source extraction.
for source_gpt in "$source_dir"/gpt_main*.bin "$source_dir"/gpt_backup*.bin; do
	name="$(basename "$source_gpt")"
	cp --remove-destination "$source_gpt" "$output_dir/$name"
done

source_persist_count="$(rg -c 'label="persist"[^>]*filename="persist\.img"|filename="persist\.img"[^>]*label="persist"' "$source_dir"/rawprogram*.xml | awk -F: '{ total += $2 } END { print total + 0 }')"
[ "$source_persist_count" -eq 1 ] || die "expected exactly one persist program entry, got $source_persist_count"

sed -i '/label="persist"/d' "$output_dir/rawprogram0.xml"

if rg -n 'label="persist"|filename="persist\.img"' "$output_dir"/rawprogram*.xml; then
	die "prepared plan still contains a persist write"
fi

source_labels="$output_dir/.source-labels"
plan_labels="$output_dir/.plan-labels"
removed_labels="$output_dir/.removed-labels"
added_labels="$output_dir/.added-labels"
rg -o --no-filename 'label="[^"]+"' "$source_dir"/rawprogram*.xml | sort > "$source_labels"
rg -o --no-filename 'label="[^"]+"' "$output_dir"/rawprogram*.xml | sort > "$plan_labels"
comm -23 "$source_labels" "$plan_labels" > "$removed_labels"
comm -13 "$source_labels" "$plan_labels" > "$added_labels"
if [ "$(cat "$removed_labels")" != 'label="persist"' ]; then
	die "plan differs from source by more than the persist program entry"
fi
if [ -s "$added_labels" ]; then
	die "plan unexpectedly adds program labels"
fi
rm "$source_labels" "$plan_labels" "$added_labels"

{
	printf 'source=%s\n' "$source_dir"
	printf 'created=%s\n' "$(date --iso-8601=seconds)"
	printf 'excluded_partition=persist\n'
	printf 'excluded_reason=per-device factory calibration and identity\n'
	printf 'phone_access=none\n'
} > "$output_dir/PLAN-MANIFEST.txt"

(
	cd "$output_dir"
	sha256sum rawprogram*.xml patch*.xml prog_firehose_ddr.elf > PLAN-SHA256SUMS
	sha256sum -c PLAN-SHA256SUMS > PLAN-SHA256SUMS.verify.txt
)

printf 'Prepared stock plan: %s\n' "$output_dir"
printf 'Excluded program target: persist\n'
printf 'Review PLAN-MANIFEST.txt and PLAN-SHA256SUMS before flashing.\n'
