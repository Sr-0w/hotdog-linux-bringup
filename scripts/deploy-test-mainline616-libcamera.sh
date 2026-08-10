#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/env.sh"
# shellcheck source=/dev/null
source "$(dirname "$0")/phone-lock.sh"

PMOS_HOST="${PMOS_HOST:-$HOTDOG_PMOS_HOST}"
PMOS_USER="${PMOS_USER:-$HOTDOG_PMOS_USER}"
PMOS_PASSWORD="${PMOS_PASSWORD:-$HOTDOG_PMOS_PASSWORD}"
PACKAGE_DIR="${PACKAGE_DIR:-$HOTDOG_PMBOOTSTRAP_WORK/packages/edge/aarch64}"
EXPECTED_KERNEL_MARKER="${EXPECTED_KERNEL_MARKER:-oneplus-hotdog-mainline616}"
stamp="$(date +%F-%H%M%S)"
OUT="${OUT:-$HOTDOG_LOG_ROOT/libcamera-deploy-test-$stamp}"
REMOTE_DIR=""
REMOTE_PRIVILEGE=""
DMESG_PID=""

usage() {
	cat <<'USAGE'
Usage: deploy-test-mainline616-libcamera.sh [options]

Install locally built libcamera packages from a RAM-backed staging directory,
then validate both rear cameras, automatic exposure/gain, IMX586 autofocus and
Plasma Camera startup. The script never flashes or reboots the phone and
refuses to run while Qualcomm 900e is visible.

Options:
  --host HOST           SSH host. Default: 172.16.42.1.
  --user USER           SSH user. Default: user.
  --password PASS       SSH/root password. Defaults to PMOS_PASSWORD.
  --package-dir DIR     Directory containing locally built libcamera APKs.
  --kernel-marker TEXT  Required substring in uname -a.
  --out DIR             Host output directory.
  -h, --help            Show this help.
USAGE
}

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	log "ERROR: $*" >&2
	exit 2
}

cleanup() {
	if [ -n "$DMESG_PID" ]; then
		pkill -TERM -P "$DMESG_PID" 2>/dev/null || true
		kill "$DMESG_PID" 2>/dev/null || true
		wait "$DMESG_PID" 2>/dev/null || true
	fi
	phone_lock_release || true
}
trap cleanup EXIT INT TERM

ssh_base() {
	sshpass -p "$PMOS_PASSWORD" ssh \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$OUT/known_hosts" \
		-o ConnectTimeout=5 \
		-o ServerAliveInterval=2 \
		-o ServerAliveCountMax=2 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$PMOS_USER@$PMOS_HOST" "$@"
}

scp_to_phone() {
	sshpass -p "$PMOS_PASSWORD" scp \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile="$OUT/known_hosts" \
		-o ConnectTimeout=5 \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no \
		"$1" "$PMOS_USER@$PMOS_HOST:$2"
}

remote_privileged() {
	case "$REMOTE_PRIVILEGE" in
		sudo-n)
			ssh_base "sudo -n $*"
			;;
		sudo-password)
			printf '%s\n' "$PMOS_PASSWORD" | ssh_base "sudo -S -p '' $*"
			;;
		doas-n)
			ssh_base "doas -n $*"
			;;
		doas-password)
			printf '%s\n' "$PMOS_PASSWORD" | ssh_base "doas $*"
			;;
		*)
			die "remote privilege mode is unset"
			;;
	esac
}

detect_remote_privilege() {
	if ssh_base 'sudo -n true' >/dev/null 2>&1; then
		REMOTE_PRIVILEGE=sudo-n
	elif printf '%s\n' "$PMOS_PASSWORD" | ssh_base "sudo -S -p '' true" >/dev/null 2>&1; then
		REMOTE_PRIVILEGE=sudo-password
	elif ssh_base 'doas -n true' >/dev/null 2>&1; then
		REMOTE_PRIVILEGE=doas-n
	elif printf '%s\n' "$PMOS_PASSWORD" | ssh_base 'doas true' >/dev/null 2>&1; then
		REMOTE_PRIVILEGE=doas-password
	else
		die "remote sudo/doas authentication failed"
	fi
}

assert_not_900e() {
	if lsusb -d 05c6:900e 2>/dev/null | grep -q .; then
		die "Qualcomm 900e is visible; recover manually before running this script"
	fi
}

assert_same_boot() {
	local current
	current="$(ssh_base 'cat /proc/sys/kernel/random/boot_id')" ||
		die "SSH disappeared while checking boot identity"
	[ "$current" = "$BOOT_ID" ] || die "boot identity changed during deployment"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--host) PMOS_HOST="$2"; shift ;;
		--user) PMOS_USER="$2"; shift ;;
		--password) PMOS_PASSWORD="$2"; shift ;;
		--package-dir) PACKAGE_DIR="$2"; shift ;;
		--kernel-marker) EXPECTED_KERNEL_MARKER="$2"; shift ;;
		--out) OUT="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "unknown argument: $1" ;;
	esac
	shift
done

[ -n "$PMOS_PASSWORD" ] || die "set PMOS_PASSWORD or use --password"
for command_name in lsusb scp sha256sum ssh sshpass; do
	command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done
assert_not_900e
phone_lock_acquire "libcamera package deployment and validation" 0 || exit $?
mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1

packages=()
for name in libcamera libcamera-ipa libcamera-tools libcamera-gstreamer; do
	mapfile -t matches < <(find "$PACKAGE_DIR" -maxdepth 1 -type f \
		-name "$name-99990.7.2-r*.apk" -print | sort -V)
	[ "${#matches[@]}" -gt 0 ] || die "missing package for $name in $PACKAGE_DIR"
	package="${matches[-1]}"
	packages+=("$package")
done

UNAME="$(ssh_base 'uname -a')" || die "phone is not reachable over SSH"
BOOT_ID="$(ssh_base 'cat /proc/sys/kernel/random/boot_id')" || die "cannot read boot identity"
# The single-quoted expression is intentionally expanded by the remote shell.
# shellcheck disable=SC2016
REMOTE_RUNTIME_DIR="$(ssh_base 'printf %s "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"')" ||
	die "cannot determine the remote runtime directory"
case "$REMOTE_RUNTIME_DIR" in
	/run/user/*) ;;
	*) die "remote runtime directory is not RAM-backed: $REMOTE_RUNTIME_DIR" ;;
esac
REMOTE_DIR="$REMOTE_RUNTIME_DIR/hotdog-libcamera-test-$stamp"
printf '%s\n' "$UNAME" | tee "$OUT/uname.txt"
printf '%s\n' "$BOOT_ID" | tee "$OUT/boot-id.txt"
[[ "$UNAME" == *"$EXPECTED_KERNEL_MARKER"* ]] ||
	die "running kernel does not contain marker: $EXPECTED_KERNEL_MARKER"
detect_remote_privilege
log "remote privilege mode: $REMOTE_PRIVILEGE"

ssh_base "mkdir -p '$REMOTE_DIR' && find '$REMOTE_DIR' -mindepth 1 -maxdepth 1 -type f -delete"
for package in "${packages[@]}"; do
	name="$(basename "$package")"
	log "staging $name in tmpfs"
	scp_to_phone "$package" "$REMOTE_DIR/$name"
	local_sha="$(sha256sum "$package" | awk '{ print $1 }')"
	remote_sha="$(ssh_base "sha256sum '$REMOTE_DIR/$name'" | awk '{ print $1 }')"
	[ "$local_sha" = "$remote_sha" ] || die "SHA256 mismatch after staging $name"
	assert_same_boot
done

log "starting host-side kernel log capture"
(
	phone_lock_prepare_detached_child
	case "$REMOTE_PRIVILEGE" in
		sudo-n) ssh_base 'sudo -n dmesg -w' ;;
		sudo-password) printf '%s\n' "$PMOS_PASSWORD" | ssh_base "sudo -S -p '' dmesg -w" ;;
		doas-n) ssh_base 'doas -n dmesg -w' ;;
		doas-password) printf '%s\n' "$PMOS_PASSWORD" | ssh_base 'doas dmesg -w' ;;
		esac
) > "$OUT/dmesg-live.txt" 2>&1 &
DMESG_PID=$!
sleep 1

log "installing libcamera packages"
remote_privileged apk add --allow-untrusted "$REMOTE_DIR"/'*.apk'
assert_not_900e
assert_same_boot
ssh_base "apk info -v | grep -E '^(libcamera|plasma-camera|pipewire-spa-libcamera)'" \
	| tee "$OUT/packages.txt"

log "validating both rear cameras and IMX586 automatic controls"
ssh_base 'pkill -x plasma-camera 2>/dev/null || true'
ssh_base "LIBCAMERA_LOG_LEVELS='*:DEBUG' cam -l" \
	> "$OUT/cam-list.txt" 2> "$OUT/cam-list.stderr"
ssh_base "LIBCAMERA_LOG_LEVELS='*:INFO,IPASoftAf:DEBUG' cam -c 1 --capture=240 --metadata -s role=viewfinder,width=640,height=480,pixelformat=XRGB8888" \
	> "$OUT/cam-ae.txt" 2> "$OUT/cam-ae.stderr"

if [ "$(grep -c 'Internal back camera' "$OUT/cam-list.txt")" -lt 2 ] ||
	! grep -q 'imx586' "$OUT/cam-list.stderr" ||
	! grep -q 's5k3m5' "$OUT/cam-list.stderr"; then
	die "IMX586 or S5K3M5 is absent from cam -l"
fi
if grep -Eqi 'no static properties|no sensor helper|no tuning file' \
	"$OUT/cam-list.stderr" "$OUT/cam-ae.stderr"; then
	die "libcamera still reports missing S5K3M5 integration data"
fi
exposure_values="$(grep -oE 'ExposureTime = [0-9]+' "$OUT/cam-ae.txt" | sort -u | wc -l)"
gain_values="$(grep -oE 'AnalogueGain = [0-9.]+' "$OUT/cam-ae.txt" | sort -u | wc -l)"
[ "$exposure_values" -gt 1 ] || die "automatic exposure did not move during the 240-frame run"
grep -q 'AfState = 2' "$OUT/cam-ae.txt" || die "IMX586 autofocus did not reach focused state"
grep -q 'Autofocus completed at' "$OUT/cam-ae.stderr" ||
	die "IMX586 autofocus did not report a completed scan"
printf 'distinct_exposure_values=%s\ndistinct_gain_values=%s\n' \
	"$exposure_values" "$gain_values" | tee "$OUT/automatic-controls.txt"

log "validating Plasma Camera integration"
ssh_base "timeout -k 2s 20s sh -lc '
	pid=\$(pgrep -n plasmashell)
	[ -n \"\$pid\" ]
	export XDG_RUNTIME_DIR=\$(tr \"\\0\" \"\\n\" < /proc/\$pid/environ | sed -n \"s/^XDG_RUNTIME_DIR=//p\")
	export WAYLAND_DISPLAY=\$(tr \"\\0\" \"\\n\" < /proc/\$pid/environ | sed -n \"s/^WAYLAND_DISPLAY=//p\")
	export DBUS_SESSION_BUS_ADDRESS=\$(tr \"\\0\" \"\\n\" < /proc/\$pid/environ | sed -n \"s/^DBUS_SESSION_BUS_ADDRESS=//p\")
	exec plasma-camera
'" > "$OUT/plasma-camera.txt" 2>&1 || true
grep -Eq 'setReadyForCapture true|Ready for capture|readyForCapture.*true' \
	"$OUT/plasma-camera.txt" || die "Plasma Camera did not reach ready-for-capture state"
assert_same_boot
log "PASS: libcamera AE/gain and Plasma Camera startup are functional"
