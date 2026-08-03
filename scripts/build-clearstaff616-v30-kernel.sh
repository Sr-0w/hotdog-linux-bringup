#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/env.sh"

source_dir="$HOTDOG_SRC_ROOT/kernel/linux-clearstaff-hotdog"
outdir="$HOTDOG_ROOT/build/clearstaff-v30-dynamic-pps"
config_source="$HOTDOG_ROOT/configs/clearstaff-hotdog-v30.config"
source_manifest="$HOTDOG_ROOT/configs/clearstaff-hotdog-v30-source.sha256"
config_sha=86103671ddc29cebef9c10f493c6b583e46af090f26dfad0eb859f2e5a30cf20
image_sha=895432d812868fb1eed238cb0a2af4570c7953e1503f38db9b9d7b9bc493bf0d
initramfs_sha=6c52ff25f2ef2c87623f2658745f3c62cc51f38a0131bafaaafafe285a899215
kernel_build_id=2cfecdea6c10d0a3724fa4eeb831ea9150eb5f55
vdso64_build_id=8ee32136b7fe2e5baa330cb2b41bc760fc9ef854
vdso32_build_id=22f05e7e0908fbb895c66458fa25ea1883689b11
jobs="${JOBS:-$(nproc)}"
tool_shim=

usage() {
	cat <<'USAGE'
Usage: build-clearstaff616-v30-kernel.sh [--source DIR] [--outdir DIR]

Rebuild the V30 kernel from the verified ClearStaff source and exact checked-in
configuration. Historical build identity and timestamp are pinned so the arm64
Image can be compared byte-for-byte with the hardware-tested artifact.
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--source) source_dir="$2"; shift ;;
		--outdir) outdir="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

cleanup() {
	[ -z "$tool_shim" ] || rm -rf -- "$tool_shim"
}

trap cleanup EXIT

check_sha() {
	local label="$1" path="$2" expected="$3" actual
	[ -s "$path" ] || die "missing $label: $path"
	actual="$(sha256sum "$path" | awk '{print $1}')"
	[ "$actual" = "$expected" ] ||
		die "$label hash mismatch: expected $expected, got $actual"
}

check_build_id() {
	local label="$1" path="$2" expected="$3"
	llvm-readelf -n "$path" | grep -Fq "Build ID: $expected" ||
		die "$label build ID mismatch"
}

for command in awk clang date grep ld.lld llvm-readelf make mktemp nproc sha256sum; do
	command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done
case "$jobs" in
	''|*[!0-9]*|0) die "JOBS must be a positive integer" ;;
esac
git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1 ||
	die "missing kernel checkout: $source_dir"
[ -r "$source_manifest" ] || die "missing source manifest: $source_manifest"
check_sha config "$config_source" "$config_sha"
[ ! -e "$outdir" ] || die "refusing to reuse output directory: $outdir"

(
	cd "$source_dir"
	sha256sum -c "$source_manifest"
	git diff --check
)

mkdir -p "$outdir"
cp "$config_source" "$outdir/.config"
make -C "$source_dir" O="$outdir" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
check_sha "generated config" "$outdir/.config" "$config_sha"

export KBUILD_BUILD_USER=srobin
export KBUILD_BUILD_HOST=Gentoo
unset KBUILD_BUILD_VERSION KBUILD_BUILD_TIMESTAMP

# V30 was built with the kernel's automatic version path. That deliberately
# leaves init/utsversion-tmp.h without a version or timestamp while the final
# generated header receives build version 1 and the wall-clock timestamp. A
# no-argument date shim recreates that contract without changing host time.
# The clang shim remaps debug paths to the historical build roots so GNU build
# IDs remain reproducible without requiring the same checkout location.
tool_shim="$(mktemp -d "${TMPDIR:-/tmp}/hotdog-v30-tools.XXXXXX")"
export HOTDOG_REAL_CLANG HOTDOG_REAL_DATE HOTDOG_SOURCE_PATH HOTDOG_OUTPUT_PATH
export HOTDOG_V30_SOURCE_PATH HOTDOG_V30_OUTPUT_PATH
HOTDOG_REAL_CLANG="$(command -v clang)"
HOTDOG_REAL_DATE="$(command -v date)"
HOTDOG_SOURCE_PATH="$source_dir"
HOTDOG_OUTPUT_PATH="$outdir"
HOTDOG_V30_SOURCE_PATH="/home/$KBUILD_BUILD_USER/dev/hotdog/src/kernel/linux-clearstaff-hotdog"
HOTDOG_V30_OUTPUT_PATH="/home/$KBUILD_BUILD_USER/dev/hotdog/build/clearstaff-v30-dynamic-pps"
cat > "$tool_shim/date" <<'SH'
#!/bin/sh
if [ "$#" -eq 0 ]; then
	printf '%s\n' 'Mon Aug  3 16:39:08 CEST 2026'
	exit 0
fi
exec "$HOTDOG_REAL_DATE" "$@"
SH
cat > "$tool_shim/clang" <<'SH'
#!/bin/sh
exec "$HOTDOG_REAL_CLANG" \
	"-fdebug-prefix-map=$HOTDOG_SOURCE_PATH=$HOTDOG_V30_SOURCE_PATH" \
	"-fdebug-prefix-map=$HOTDOG_OUTPUT_PATH=$HOTDOG_V30_OUTPUT_PATH" \
	"$@"
SH
chmod 0755 "$tool_shim/date" "$tool_shim/clang"
export PATH="$tool_shim:$PATH"

make -C "$source_dir" O="$outdir" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
	-j "$jobs" Image qcom/sm8150-oneplus-hotdog.dtb

# The empty built-in initramfs uses time(2), not the date utility. Normalize
# its three cpio mtimes to the timestamp present in the hardware-tested Image,
# then relink without changing the recorded no-argument kbuild command.
(
	cd "$outdir"
	sh "$source_dir/usr/gen_initramfs.sh" \
		-o usr/initramfs_data.cpio \
		-l usr/.initramfs_data.cpio.d \
		-d @1785767663 \
		"$source_dir/usr/default_cpio_list"
)
check_sha "built-in initramfs" "$outdir/usr/initramfs_data.cpio" "$initramfs_sha"
printf '0\n' > "$outdir/.version"
make -C "$source_dir" O="$outdir" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
	-j "$jobs" Image qcom/sm8150-oneplus-hotdog.dtb

grep -qx '#define UTS_VERSION "# SMP PREEMPT "' \
	"$outdir/init/utsversion-tmp.h" || die "unexpected temporary UTS version"
grep -qx '#define UTS_VERSION "#1 SMP PREEMPT Mon Aug  3 16:39:08 CEST 2026"' \
	"$outdir/include/generated/utsversion.h" || die "unexpected final UTS version"
check_build_id kernel "$outdir/vmlinux" "$kernel_build_id"
check_build_id "64-bit vDSO" \
	"$outdir/arch/arm64/kernel/vdso/vdso.so.dbg" "$vdso64_build_id"
check_build_id "32-bit vDSO" \
	"$outdir/arch/arm64/kernel/vdso32/vdso32.so.dbg" "$vdso32_build_id"
check_sha "V30 arm64 Image" "$outdir/arch/arm64/boot/Image" "$image_sha"
grep -qx 'CONFIG_DRM_PANEL_SAMSUNG_ONEPLUS_DSC=y' "$outdir/.config" ||
	die "native OnePlus panel is not built in"
grep -aFq 'samsung,oneplus-dsc' "$outdir/arch/arm64/boot/Image" ||
	die "native OnePlus panel compatible is absent from the Image"

sha256sum "$outdir/arch/arm64/boot/Image" \
	"$outdir/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dtb" \
	"$outdir/.config" > "$outdir/V30-SHA256SUMS"
printf 'Reproduced V30 kernel: %s\n' "$outdir/arch/arm64/boot/Image"
