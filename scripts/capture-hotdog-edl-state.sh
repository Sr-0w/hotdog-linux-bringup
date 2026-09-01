#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
	cat <<'EOF'
Usage: capture-hotdog-edl-state.sh --state NAME --edl-ng FILE --loader FILE [--output-root DIR]

Capture a reproducible, read-only EDL state for the OnePlus 7T Pro (hotdog):
live GPT text, primary/backup GPT sectors, two matching reads of per-device
critical partitions, and every named partition except encrypted userdata.
EOF
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

state=""
edl_bin=""
loader=""
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="$repo_root/backups/lineage-boot-state"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--state) state="${2:-}"; shift ;;
		--edl-ng) edl_bin="${2:-}"; shift ;;
		--loader) loader="${2:-}"; shift ;;
		--output-root) output_root="${2:-}"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
	shift
done

[[ "$state" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid or missing state name"
[ -x "$edl_bin" ] || die "missing executable edl-ng: $edl_bin"
[ -s "$loader" ] || die "missing Firehose loader: $loader"
for tool in awk cmp find lsusb sha256sum sort stat timeout; do
	command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

usb_snapshot="$(lsusb)"
[ "$(printf '%s\n' "$usb_snapshot" | rg -ci '05c6:9008')" -eq 1 ] || die "exactly one Qualcomm 05c6:9008 device is required"
! printf '%s\n' "$usb_snapshot" | rg -qi '05c6:900e' || die "device is in crashdump mode, not EDL Firehose"

mkdir -p "$output_root"
lock_dir="$output_root/.capture.lock"
mkdir "$lock_dir" 2>/dev/null || die "another EDL state capture appears active: $lock_dir"
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

stamp="$(date +%F-%H%M%S)"
out="$output_root/${stamp}-${state}"
[ ! -e "$out" ] || die "capture path already exists: $out"
mkdir -p "$out/gpt/raw" "$out/critical/primary" "$out/critical/verify" \
	"$out/partitions" "$out/logs/critical" "$out/logs/partitions" "$out/logs/gpt-raw"
printf '%s\n' "$usb_snapshot" > "$out/lsusb.txt"
sha256sum "$loader" > "$out/loader.sha256"

edl_base=("$edl_bin" --loader "$loader" --memory Ufs)
"${edl_base[@]}" --loglevel Info printgpt 2>&1 | tee "$out/gpt/printgpt.txt"

awk '
	/GPT Header LUN [0-9]+/ { line=$0; sub(/^.*GPT Header LUN /, "", line); sub(/ .*/, "", line); lun=line }
	/Name: / { line=$0; sub(/^.*Name: /, "", line); print lun ":" line }
' "$out/gpt/printgpt.txt" > "$out/PARTITION-LUN-MAP.txt"
[ "$(wc -l < "$out/PARTITION-LUN-MAP.txt")" -ge 80 ] || die "parsed partition map is unexpectedly short"

awk '
	/GPT Header LUN [0-9]+/ { line=$0; sub(/^.*GPT Header LUN /, "", line); sub(/ .*/, "", line); lun=line }
	/Backup LBA:/ { print lun ":" $NF }
' "$out/gpt/printgpt.txt" > "$out/gpt/BACKUP-LBA.txt"
[ "$(wc -l < "$out/gpt/BACKUP-LBA.txt")" -eq 6 ] || die "expected six UFS LUN backup LBAs"

while IFS=: read -r lun backup_lba; do
	backup_start=$((backup_lba - 4))
	timeout 240 "${edl_base[@]}" read-sector 0 6 "$out/gpt/raw/lun${lun}-primary.bin" --lun "$lun" > "$out/logs/gpt-raw/lun${lun}-primary.txt" 2>&1
	timeout 240 "${edl_base[@]}" read-sector "$backup_start" 5 "$out/gpt/raw/lun${lun}-backup.bin" --lun "$lun" > "$out/logs/gpt-raw/lun${lun}-backup.txt" 2>&1
done < "$out/gpt/BACKUP-LBA.txt"

critical=(
	0:ssd 0:persist 0:misc 0:param 0:keystore 0:frp 0:oem_dycnvbk 0:oem_stanvbk
	0:mdm_oem_dycnvbk 0:mdm_oem_stanvbk 0:config 3:cdt 3:ddr 3:mdmddr
	4:aging 4:aging_mod 4:devinfo 4:dip 4:apdp 4:msadp 4:spunvm 4:limits
	4:storsec_a 4:storsec_b 4:uefivarstore 4:secdata 4:reserve1 4:reserve2
	4:reserve3 4:reserve4 4:mdm1oemnvbktmp 5:modemst1 5:modemst2 5:fsg 5:fsc
	5:mdm1m9kefs3 5:mdm1m9kefs1 5:mdm1m9kefs2 5:mdm1m9kefsc
)
: > "$out/critical/PARTITION-LUN-MAP.txt"
for item in "${critical[@]}"; do
	lun="${item%%:*}"
	part="${item#*:}"
	printf '%s %s\n' "$lun" "$part" >> "$out/critical/PARTITION-LUN-MAP.txt"
	for pass in primary verify; do
		image="$out/critical/$pass/$part.img"
		timeout 240 "${edl_base[@]}" read-part "$part" "$image" --lun "$lun" > "$out/logs/critical/$pass-$part.txt" 2>&1
		[ -s "$image" ] || die "empty critical image: $image"
	done
done

(
	cd "$out/critical/primary"
	sha256sum *.img | sort -k2 > ../SHA256SUMS.primary
)
(
	cd "$out/critical/verify"
	sha256sum *.img | sort -k2 > ../SHA256SUMS.verify
)
cmp "$out/critical/SHA256SUMS.primary" "$out/critical/SHA256SUMS.verify" || die "critical read verification mismatch"
printf 'VERIFIED: two independent reads match for %s partitions\n' "${#critical[@]}" > "$out/critical/VERIFICATION.txt"

printf 'userdata\treason=encrypted_221GiB_out_of_boot-state_scope\n' > "$out/EXCLUSIONS.txt"
while IFS=: read -r lun part; do
	[ "$part" != userdata ] || continue
	image="$out/partitions/lun${lun}-${part}.img"
	critical_image="$out/critical/primary/$part.img"
	if [ -s "$critical_image" ] && awk -v l="$lun" -v p="$part" '$1 == l && $2 == p { found=1 } END { exit !found }' "$out/critical/PARTITION-LUN-MAP.txt"; then
		ln "$critical_image" "$image"
	else
		timeout 1800 "${edl_base[@]}" read-part "$part" "$image" --lun "$lun" > "$out/logs/partitions/lun${lun}-${part}.txt" 2>&1
		[ -s "$image" ] || die "empty partition image: $image"
	fi
done < "$out/PARTITION-LUN-MAP.txt"

(
	cd "$out"
	sha256sum gpt/raw/*.bin partitions/*.img | sort -k2 > SHA256SUMS
	sha256sum -c SHA256SUMS > SHA256SUMS.verify.txt
	find gpt/raw partitions -type f -printf '%s %p\n' | sort -k2 > SIZES.txt
)
{
	printf 'state=%s\n' "$state"
	printf 'created=%s\n' "$(date --iso-8601=seconds)"
	printf 'mode=read-only\n'
	printf 'device=oneplus-hotdog-HD1913-project-19801\n'
	printf 'excluded=userdata\n'
	printf 'critical_double_reads=%s\n' "${#critical[@]}"
} > "$out/MANIFEST.txt"
printf 'Capture complete: %s\n' "$out"

