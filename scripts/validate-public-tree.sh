#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

log() {
	printf '[public-tree] %s\n' "$*"
}

die() {
	printf '[public-tree] ERROR: %s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

shellcheck_mainline616_validator() {
	local validator="$1"
	local report_file
	local status

	report_file="$(mktemp)"
	status=0
	shellcheck --format=json --severity=warning --shell=sh -- "$validator" >"$report_file" 2>&1 ||
		status=$?
	if [ "$status" -eq 0 ]; then
		rm -f -- "$report_file"
		return 0
	fi
	[ "$status" -eq 1 ] || {
		cat -- "$report_file" >&2
		rm -f -- "$report_file"
		return "$status"
	}

	if python3 - "$validator" "$report_file" <<'PY'
import json
import sys

validator = sys.argv[1]
report_path = sys.argv[2]
with open(report_path, encoding="utf-8") as report_file:
    report = json.load(report_file)
comments = report.get("comments", []) if isinstance(report, dict) else report

unexpected = []
for comment in comments:
    is_known_typec_alias = (
        comment.get("code") == 2034
        and comment.get("file") == validator
        and "pm8150b_typec appears unused" in comment.get("message", "")
    )
    if not is_known_typec_alias:
        unexpected.append(comment)

if unexpected:
    for comment in unexpected:
        print(
            f"{comment.get('file', validator)}:{comment.get('line', 0)}:"
            f"{comment.get('column', 0)}: {comment.get('level', 'error')} "
            f"SC{comment.get('code', '????')}: {comment.get('message', '')}",
            file=sys.stderr,
        )
    raise SystemExit(1)
PY
	then
		rm -f -- "$report_file"
		return 0
	fi

	rm -f -- "$report_file"
	return 1
}

validate_shell_scripts() {
	local -a shell_scripts=()
	local shell_script

	mapfile -d '' -t shell_scripts < <(
		find scripts -maxdepth 1 -type f -name '*.sh' -print0 | sort -z
	)
	[ "${#shell_scripts[@]}" -gt 0 ] || die "no scripts/*.sh files found"

	log "bash -n (${#shell_scripts[@]} scripts)"
	for shell_script in "${shell_scripts[@]}"; do
		bash -n "$shell_script"
	done

	log "ShellCheck severity=warning (${#shell_scripts[@]} scripts)"
	shellcheck --severity=warning -- "${shell_scripts[@]}"
}

validate_python_syntax() {
	local -a python_files=()

	mapfile -d '' -t python_files < <(git ls-files -z -- '*.py')
	if [ "${#python_files[@]}" -eq 0 ]; then
		log "Python syntax: no tracked Python files"
		return
	fi

	log "Python syntax (${#python_files[@]} files, no bytecode writes)"
	python3 - "${python_files[@]}" <<'PY'
from pathlib import Path
import sys
import tokenize

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    with tokenize.open(path) as source_file:
        source = source_file.read()
    compile(source, str(path), "exec", dont_inherit=True)
PY
}

validate_markdown_links() {
	local -a markdown_files=()

	mapfile -d '' -t markdown_files < <(git ls-files -z -- '*.md')
	if [ "${#markdown_files[@]}" -eq 0 ]; then
		log "Markdown links: no tracked Markdown files"
		return
	fi

	log "local Markdown links (${#markdown_files[@]} files)"
	python3 - "$REPO_ROOT" "${markdown_files[@]}" <<'PY'
from pathlib import Path
import os
import re
import sys
from urllib.parse import unquote, urlsplit

root = Path(sys.argv[1]).resolve()
inline_link = re.compile(r"!?\[[^\]\n]*\]\(([^)\n]+)\)")
reference_link = re.compile(r"^\s{0,3}\[[^\]\n]+\]:\s*(.+?)\s*$")
fence_marker = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
inline_code = re.compile(r"`[^`]*`")
errors = []


def visible_lines(text):
    fence = None
    for line_number, line in enumerate(text.splitlines(), 1):
        marker = fence_marker.match(line)
        if marker:
            marker_type = marker.group(1)[0]
            if fence is None:
                fence = marker_type
            elif fence == marker_type:
                fence = None
            continue
        if fence is None:
            yield line_number, inline_code.sub("", line)


def destination(raw):
    raw = raw.strip()
    if raw.startswith("<"):
        end = raw.find(">", 1)
        return raw[1:end] if end != -1 else raw
    return raw.split(None, 1)[0] if raw else ""


def check_target(markdown_path, line_number, raw_target):
    target = destination(raw_target)
    if not target or target.startswith(("#", "//")):
        return

    parsed = urlsplit(target)
    if parsed.scheme:
        return

    local_path = unquote(parsed.path)
    if not local_path:
        return

    if local_path.startswith("/"):
        candidate = root / local_path.lstrip("/")
    else:
        candidate = markdown_path.parent / local_path
    candidate = candidate.resolve()

    try:
        inside_root = os.path.commonpath((root, candidate)) == str(root)
    except ValueError:
        inside_root = False
    if not inside_root:
        errors.append(
            f"{markdown_path.relative_to(root)}:{line_number}: "
            f"local link escapes repository: {target}"
        )
    elif not candidate.exists():
        errors.append(
            f"{markdown_path.relative_to(root)}:{line_number}: "
            f"missing local link target: {target}"
        )


for relative_path in sys.argv[2:]:
    markdown_path = (root / relative_path).resolve()
    text = markdown_path.read_text(encoding="utf-8")
    for line_number, line in visible_lines(text):
        for match in inline_link.finditer(line):
            check_target(markdown_path, line_number, match.group(1))
        reference = reference_link.match(line)
        if reference:
            check_target(markdown_path, line_number, reference.group(1))

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
}

check_forbidden_pattern() {
	local label="$1"
	local pattern="$2"
	local matches
	local status

	if matches="$(git grep -I -n -E -e "$pattern" -- .)"; then
		printf '%s\n' "$matches" >&2
		die "forbidden $label found in tracked files"
	else
		status=$?
		[ "$status" -eq 1 ] || die "git grep failed while checking $label"
	fi
}

validate_public_markers() {
	local workstation_path
	local device_identifier
	local fake_email_pattern

	workstation_path='/home/'srobin
	device_identifier='b6bd''2252'
	fake_email_pattern='[[:alnum:]._%+-]+@([[:alnum:].-]+[.]invalid|example[.](com|org|net))'

	log "public-tree private marker scan"
	check_forbidden_pattern "workstation path" "$workstation_path"
	check_forbidden_pattern "device identifier" "$device_identifier"
	check_forbidden_pattern "placeholder email" "$fake_email_pattern"
}

assert_identical() {
	local canonical="$1"
	local copy="$2"

	[ -f "$canonical" ] || die "missing canonical K1 patch: $canonical"
	[ -f "$copy" ] || die "missing duplicated K1 patch: $copy"
	cmp -s -- "$canonical" "$copy" || die "K1 patch copies differ: $canonical != $copy"
}

validate_k1_patch_copies() {
	local aport_dir="aports/device/testing/linux-oneplus-hotdog-mainline617-k1"

	log "K1 duplicated patch identity"
	assert_identical \
		"patches/experimental-android-kernel-entry-layout.patch" \
		"$aport_dir/0001-arm64-hotdog-use-android-entry-layout.patch"
	assert_identical \
		"patches/mainline-fts-strict-prototypes.patch" \
		"$aport_dir/0002-input-fts-fix-strict-prototypes.patch"
	assert_identical \
		"patches/mainline-hotdog-k1-dts.patch" \
		"$aport_dir/0004-arm64-dts-qcom-add-oneplus-hotdog.patch"
}

verify_sha512() {
	local expected="$1"
	local file="$2"
	local actual

	actual="$(sha512sum -- "$file")"
	actual="${actual%% *}"
	[ "$actual" = "$expected" ] || die "SHA512 mismatch for $file: expected $expected, got $actual"
}

validate_k1_aport_inputs() {
	local aport_dir="aports/device/testing/linux-oneplus-hotdog-mainline617-k1"
	local apkbuild="$aport_dir/APKBUILD"
	local transform="$aport_dir/transform-k1-dtb.sh"
	local line
	local expected
	local filename
	local checksum_count=0
	local local_count=0
	local source_count=0
	local tar_count=0
	local in_source=0

	[ -f "$apkbuild" ] || die "missing K1 APKBUILD: $apkbuild"
	log "K1 aport SHA512 inputs"
	[ -x "$transform" ] || die "missing executable K1 DTB transform: $transform"
	sh -n "$transform"
	shellcheck --severity=warning --shell=sh -- "$transform"

	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$in_source" -eq 0 ]; then
			[[ "$line" =~ ^source=\"[[:space:]]*$ ]] && in_source=1
			continue
		fi
		[[ "$line" =~ ^[[:space:]]*\"[[:space:]]*$ ]] && break
		[[ "$line" =~ ^[[:space:]]*$ ]] || ((source_count += 1))
	done < "$apkbuild"
	[ "$source_count" -gt 0 ] || die "could not parse K1 source entries from $apkbuild"

	while IFS= read -r line || [ -n "$line" ]; do
		if [[ "$line" =~ ^([0-9a-f]{128})[[:space:]]+([^[:space:]]+)$ ]]; then
			expected="${BASH_REMATCH[1]}"
			filename="${BASH_REMATCH[2]}"
			((checksum_count += 1))

			if [[ "$filename" == *.tar.bz2 ]]; then
				((tar_count += 1))
				if [ -f "$aport_dir/$filename" ]; then
					verify_sha512 "$expected" "$aport_dir/$filename"
				else
					log "skip absent remote source tarball: $filename"
				fi
				continue
			fi

			((local_count += 1))
			[ -f "$aport_dir/$filename" ] || die "missing local K1 aport input: $aport_dir/$filename"
			verify_sha512 "$expected" "$aport_dir/$filename"
		fi
	done < "$apkbuild"

	[ "$checksum_count" -eq "$source_count" ] || die \
		"expected one K1 SHA512 entry per source ($source_count), found $checksum_count"
	[ "$tar_count" -eq 1 ] || die "expected one K1 remote source tarball entry, found $tar_count"
	[ "$local_count" -eq $((source_count - tar_count)) ] || die \
		"expected $((source_count - tar_count)) K1 local inputs, found $local_count"
}

validate_mainline616_aport_inputs() {
	local aport_dir="aports/device/testing/linux-oneplus-hotdog-mainline616"
	local apkbuild="$aport_dir/APKBUILD"
	local validator="$aport_dir/validate-mainline616-build.sh"
	local line
	local expected
	local filename
	local checksum_count=0
	local local_count=0
	local source_count=0
	local tar_count=0
	local in_source=0

	[ -f "$apkbuild" ] || die "missing mainline 6.16 APKBUILD: $apkbuild"
	[ -f "$validator" ] || die "missing mainline 6.16 validator: $validator"
	log "mainline 6.16 aport SHA512 inputs"
	sh -n "$validator"
	shellcheck_mainline616_validator "$validator"

	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$in_source" -eq 0 ]; then
			[[ "$line" =~ ^source=\"[[:space:]]*$ ]] && in_source=1
			continue
		fi
		[[ "$line" =~ ^[[:space:]]*\"[[:space:]]*$ ]] && break
		[[ "$line" =~ ^[[:space:]]*$ ]] || ((source_count += 1))
	done < "$apkbuild"
	[ "$source_count" -gt 0 ] || die "could not parse mainline 6.16 sources from $apkbuild"

	while IFS= read -r line || [ -n "$line" ]; do
		if [[ "$line" =~ ^([0-9a-f]{128})[[:space:]]+([^[:space:]]+)$ ]]; then
			expected="${BASH_REMATCH[1]}"
			filename="${BASH_REMATCH[2]}"
			((checksum_count += 1))

			if [[ "$filename" == *.tar.gz ]]; then
				((tar_count += 1))
				if [ -f "$aport_dir/$filename" ]; then
					verify_sha512 "$expected" "$aport_dir/$filename"
				else
					log "skip absent mainline 6.16 source tarball: $filename"
				fi
				continue
			fi

			((local_count += 1))
			[ -f "$aport_dir/$filename" ] ||
				die "missing local mainline 6.16 aport input: $aport_dir/$filename"
			verify_sha512 "$expected" "$aport_dir/$filename"
		fi
	done < "$apkbuild"

	[ "$checksum_count" -eq "$source_count" ] || die \
		"expected one mainline 6.16 SHA512 entry per source ($source_count), found $checksum_count"
	[ "$tar_count" -eq 1 ] || die \
		"expected one mainline 6.16 remote source tarball entry, found $tar_count"
	[ "$local_count" -eq $((source_count - tar_count)) ] || die \
		"expected $((source_count - tar_count)) mainline 6.16 local inputs, found $local_count"
}

validate_hotdog_wifi_package_contract() {
	local device_apkbuild="aports/device/testing/device-oneplus-hotdog/APKBUILD"
	local firmware_apkbuild="aports/device/testing/firmware-oneplus-hotdog/APKBUILD"

	log "hotdog WCN3990 package contract"
	grep -q 'firmware-oneplus-hotdog-wlan' "$device_apkbuild" ||
		die "device firmware package does not depend on WLAN firmware"
	grep -q 'firmware-oneplus-hotdog-modem' "$device_apkbuild" ||
		die "device firmware package does not depend on MPSS firmware"
	grep -q '^[[:space:]]*rmtfs$' "$device_apkbuild" ||
		die "device firmware package does not depend on RMTFS"
	grep -q '^[[:space:]]*rmtfs-openrc$' "$device_apkbuild" ||
		die "device firmware package does not depend on the RMTFS OpenRC service"
	grep -q '^rc-update add rmtfs boot$' \
		"aports/device/testing/device-oneplus-hotdog/device-oneplus-hotdog-nonfree-firmware.post-install" ||
		die "device firmware package does not enable RMTFS at boot"
	grep -q '^[[:space:]]*msm-modem-uim-selection$' "$device_apkbuild" ||
		die "device firmware package does not depend on UIM slot selection"
	grep -q '^rc-update add msm-modem-uim-selection boot$' \
		"aports/device/testing/device-oneplus-hotdog/device-oneplus-hotdog-nonfree-firmware.post-install" ||
		die "device firmware package does not enable UIM slot selection"
	grep -q '^[[:space:]]*modemmanager-openrc$' "$device_apkbuild" ||
		die "device firmware package does not depend on the ModemManager OpenRC service"
	grep -q '^rc-update del modemmanager default' \
		"aports/device/testing/device-oneplus-hotdog/device-oneplus-hotdog-nonfree-firmware.post-install" ||
		die "device firmware package leaves ModemManager racing in the default runlevel"
	grep -q '^rc-update del modemmanager boot' \
		"aports/device/testing/device-oneplus-hotdog/device-oneplus-hotdog-nonfree-firmware.post-install" ||
		die "device firmware package leaves ModemManager racing in the boot runlevel"
	if grep -q '^rc-update add modemmanager ' \
		"aports/device/testing/device-oneplus-hotdog/device-oneplus-hotdog-nonfree-firmware.post-install"; then
		die "device firmware package enables ModemManager before PDC readiness"
	fi
	grep -q '^[[:space:]]*hotdog-radio-bootstrap$' "$device_apkbuild" ||
		die "device firmware package lacks the radio bootstrap"
	grep -q '^[[:space:]]*hotdog-radio-bootstrap-openrc$' "$device_apkbuild" ||
		die "device firmware package lacks the radio bootstrap service"
	grep -q '^[[:space:]]*install="\$subpkgname.post-install"$' "$device_apkbuild" ||
		die "device firmware post-install is not attached to the firmware subpackage"
	grep -q '^rc-update add hotdog-radio-bootstrap boot$' \
		"aports/device/testing/device-oneplus-hotdog/device-oneplus-hotdog-nonfree-firmware.post-install" ||
		die "device firmware package does not enable the guarded radio bootstrap"
	grep -q 'depends="\$pkgname=\$pkgver-r\$pkgrel modemmanager-openrc postmarketos-ui-plasma-mobile postmarketos-ui-plasma-mobile-openrc"' \
		"aports/device/testing/hotdog-radio-bootstrap/APKBUILD" ||
		die "radio bootstrap OpenRC package does not order after the Plasma modem service"
	grep -q '^rc-update del modemmanager default' \
		"aports/device/testing/hotdog-radio-bootstrap/hotdog-radio-bootstrap-openrc.post-install" ||
		die "radio bootstrap OpenRC policy leaves ModemManager in the default runlevel"
	grep -q '^rc-update add hotdog-radio-bootstrap boot$' \
		"aports/device/testing/hotdog-radio-bootstrap/hotdog-radio-bootstrap-openrc.post-install" ||
		die "radio bootstrap OpenRC policy does not enable its guarded service"
	grep -q '^rc-update add hotdog-radio-supervisor boot$' \
		"aports/device/testing/hotdog-radio-bootstrap/hotdog-radio-bootstrap-openrc.post-install" ||
		die "radio bootstrap OpenRC policy does not enable its lifecycle supervisor"
	grep -q 'hotdog-radio-supervisord' \
		"aports/device/testing/hotdog-radio-bootstrap/APKBUILD" ||
		die "radio bootstrap package does not build the lifecycle supervisor"
	grep -q 'hotdog-radio-reattest.c' \
		"aports/device/testing/hotdog-radio-bootstrap/APKBUILD" ||
		die "radio supervisor package omits post-PIN request validation"
	grep -q 'hotdog-imsd' \
		"aports/device/testing/hotdog-radio-bootstrap/APKBUILD" ||
		die "radio bootstrap package does not build the IMSA owner"
	grep -q '^command="/usr/libexec/hotdog-radio-supervisord"$' \
		"aports/device/testing/hotdog-radio-bootstrap/hotdog-radio-supervisor.initd" ||
		die "radio supervisor OpenRC service has the wrong executable"
	grep -q 'HOTDOG_PDC_APPROVAL' \
		"aports/device/testing/hotdog-radio-bootstrap/hotdog-radio-supervisor.initd" ||
		die "radio supervisor service has no explicit approval input"
	grep -q '^command="/usr/libexec/hotdog-imsd"$' \
		"aports/device/testing/hotdog-radio-bootstrap/hotdog-imsd.initd" ||
		die "IMSA OpenRC service has the wrong executable"
	grep -q '^[[:space:]]*use hotdog-imsd$' \
		"aports/temp/modemmanager/modemmanager.initd" ||
		die "ModemManager is not soft-ordered after the IMSA owner"
	grep -q '"$builddir"/board-2.bin' "$firmware_apkbuild" ||
		die "WLAN package does not install board-2.bin"
	grep -q '"$builddir"/firmware-5.bin' "$firmware_apkbuild" ||
		die "WLAN package does not install firmware-5.bin"
	grep -q '"$builddir"/wlanmdsp.mbn' "$firmware_apkbuild" ||
		die "WLAN package does not install wlanmdsp.mbn"
	grep -q '"$builddir"/modem.mbn' "$firmware_apkbuild" ||
		die "modem package does not install modem.mbn"
}

validate_modemmanager_slot_pin_contract() {
	local apkbuild="aports/temp/modemmanager/APKBUILD"
	local patch="aports/temp/modemmanager/0002-qmi-use-the-SIM-slot-for-PIN-operations.patch"
	local slot_patch="aports/temp/modemmanager/0003-qmi-prefer-populated-active-SIM-slot.patch"
	local voice_patch="aports/temp/modemmanager/0004-qmi-voice-preserve-numberless-calls.patch"
	local sms_ims_patch="aports/temp/modemmanager/0005-qmi-preserve-sms-ims-transport-domain.patch"
	local voice_ims_patch="aports/temp/modemmanager/0006-qmi-select-ip-voice-calls-from-ims-state.patch"
	local pin_reattest_patch="aports/temp/modemmanager/0007-qmi-request-radio-reattest-after-PIN.patch"

	log "ModemManager QMI SIM-slot PIN contract"
	[ -f "$apkbuild" ] || die "missing ModemManager override"
	[ -f "$patch" ] || die "missing ModemManager SIM-slot PIN patch"
	[ -f "$slot_patch" ] || die "missing ModemManager populated-slot patch"
	[ -f "$voice_patch" ] || die "missing ModemManager QMI Voice call-list patch"
	[ -f "$sms_ims_patch" ] || die "missing ModemManager SMS-over-IMS patch"
	[ -f "$voice_ims_patch" ] || die "missing ModemManager IP Voice dial patch"
	[ -f "$pin_reattest_patch" ] || die "missing ModemManager post-PIN re-attestation patch"
	grep -q '0002-qmi-use-the-SIM-slot-for-PIN-operations.patch' "$apkbuild" ||
		die "ModemManager override does not apply the SIM-slot PIN patch"
	grep -q '0007-qmi-request-radio-reattest-after-PIN.patch' "$apkbuild" ||
		die "ModemManager override does not apply post-PIN re-attestation"
	grep -q 'request_radio_reattest' "$pin_reattest_patch" ||
		die "successful PIN does not request guarded re-attestation"
	grep -q 'O_NOFOLLOW' "$pin_reattest_patch" ||
		die "post-PIN request does not reject path substitution"
	grep -q 'qmi_message_uim_verify_pin_input_set_session' "$patch" ||
		die "ModemManager patch does not cover PIN verification"
	grep -q 'qmi_message_uim_unblock_pin_input_set_session' "$patch" ||
		die "ModemManager patch does not cover PIN unblock"
	grep -q 'qmi_message_uim_change_pin_input_set_session' "$patch" ||
		die "ModemManager patch does not cover PIN changes"
	grep -q 'qmi_message_uim_set_pin_protection_input_set_session' "$patch" ||
		die "ModemManager patch does not cover PIN protection"
	[ "$(grep -c '^+[[:space:]]*get_uim_card_session_type (self),' "$patch")" -eq 4 ] ||
		die "ModemManager patch does not route all four PIN operations through the SIM slot"
	for slot in 2 3 4 5; do
		grep -q "QMI_UIM_SESSION_TYPE_CARD_SLOT_$slot" "$patch" ||
			die "ModemManager patch does not map card slot $slot"
	done
	grep -q '0003-qmi-prefer-populated-active-SIM-slot.patch' "$apkbuild" ||
		die "ModemManager override does not apply the populated-slot patch"
	grep -q 'empty slots. Prefer the first active slot that actually has a card' "$slot_patch" ||
		die "ModemManager populated-slot patch lacks the DSDS empty-slot guard"
	grep -q '0004-qmi-voice-preserve-numberless-calls.patch' "$apkbuild" ||
		die "ModemManager override does not apply the QMI Voice call-list patch"
	grep -q 'if (!qmi_call_information_list)' "$voice_patch" ||
		die "ModemManager QMI Voice patch still requires a remote-party number"
	grep -q 'QMI_VOICE_PRESENTATION_ALLOWED' "$voice_patch" ||
		die "ModemManager QMI Voice patch does not enforce number presentation"
	grep -q 'QMI_VOICE_CALL_TYPE_SUPS' "$voice_patch" ||
		die "ModemManager QMI Voice patch does not filter control sessions"
	grep -q '0005-qmi-preserve-sms-ims-transport-domain.patch' "$apkbuild" ||
		die "ModemManager override does not apply the SMS-over-IMS patch"
	for marker in \
		qmi_message_wms_raw_send_input_set_sms_on_ims \
		qmi_message_wms_send_from_memory_storage_input_set_sms_on_ims \
		qmi_message_wms_send_ack_input_set_sms_on_ims; do
		grep -q "$marker" "$sms_ims_patch" ||
			die "ModemManager SMS-over-IMS patch lacks $marker"
	done
	grep -q 'O_RDONLY | O_CLOEXEC | O_NOFOLLOW' "$sms_ims_patch" ||
		die "ModemManager SMS-over-IMS state reader follows unsafe files"
	grep -q 'generation > G_MAXUINT' "$sms_ims_patch" ||
		die "ModemManager SMS-over-IMS state reader accepts unbounded generations"
	grep -q '0006-qmi-select-ip-voice-calls-from-ims-state.patch' "$apkbuild" ||
		die "ModemManager override does not apply the IP Voice dial patch"
	for marker in \
		QMI_VOICE_CALL_TYPE_VOICE_IP \
		qmi_message_voice_dial_call_input_set_audio_attributes \
		qmi_message_voice_dial_call_input_set_video_attributes; do
		grep -q "$marker" "$voice_ims_patch" ||
			die "ModemManager IP Voice patch lacks $marker"
	done
	grep -q "sed -i 's|\^Exec=\.\*|Exec=/bin/false|'" "$apkbuild" ||
		die "ModemManager D-Bus activation bypasses the pre-online gate"
}

validate_libqmi_pdc_subscription_contract() {
	local apkbuild="aports/temp/libqmi/APKBUILD"
	local patch="aports/temp/libqmi/0001-pdc-add-subscription-id.patch"
	local voice_patch="aports/temp/libqmi/0002-voice-expose-ip-call-dial-attributes.patch"

	log "libqmi DSDS PDC subscription contract"
	[ -f "$apkbuild" ] || die "missing libqmi override"
	[ -f "$patch" ] || die "missing libqmi PDC subscription patch"
	[ -f "$voice_patch" ] || die "missing libqmi Voice Dial attributes patch"
	grep -q '0001-pdc-add-subscription-id.patch' "$apkbuild" ||
		die "libqmi override does not apply the PDC subscription patch"
	[ "$(grep -c '^+[[:space:]]*"id"[[:space:]]*:[[:space:]]*"0x11"' "$patch")" -eq 3 ] ||
		die "libqmi patch does not add subscription TLV 0x11 to get, set and deactivate"
	[ "$(grep -c '^+[[:space:]]*"id"[[:space:]]*:[[:space:]]*"0x12"' "$patch")" -eq 1 ] ||
		die "libqmi patch does not add subscription TLV 0x12 to activate"
	grep -q 'qmi_message_pdc_get_selected_config_input_set_subscription_id' "$patch" ||
		die "qmicli cannot query the selected config for a subscription"
	grep -q 'qmi_message_pdc_set_selected_config_input_set_subscription_id' "$patch" ||
		die "qmicli cannot select a config for a subscription"
	grep -q 'qmi_message_pdc_activate_config_input_set_subscription_id' "$patch" ||
		die "qmicli cannot activate a config for a subscription"
	grep -q 'qmi_message_pdc_deactivate_config_input_set_subscription_id' "$patch" ||
		die "qmicli cannot deactivate a config for a subscription"
	grep -q 'pdc_subscription_id > 2' "$patch" ||
		die "qmicli PDC subscription option is not bounded"
	grep -q '0002-voice-expose-ip-call-dial-attributes.patch' "$apkbuild" ||
		die "libqmi override does not apply the Voice Dial attributes patch"
	for marker in '"id"            : "0x10"' \
		'"id"            : "0x18"' '"id"            : "0x19"'; do
		grep -q "$marker" "$voice_patch" ||
			die "libqmi Voice Dial patch lacks $marker"
	done
}

validate_oxygenos_modem_inventory_contract() {
	local inventory="scripts/inventory-oxygenos-modem-stack.py"
	local firmware_inventory="scripts/inventory-oxygenos-modem-firmware.py"
	local evidence="docs/evidence/2026-08-24-oxygenos-modem-stack-architecture.md"

	log "OxygenOS modem stack inventory contract"
	[ -x "$inventory" ] || die "missing executable OxygenOS modem stack inventory"
	[ -x "$firmware_inventory" ] || die "missing executable OxygenOS modem firmware inventory"
	[ -f "$evidence" ] || die "missing OxygenOS modem stack architecture evidence"
	for marker in qcrild netmgrd imsqmidaemon imsdatadaemon rmt_storage; do
		grep -q "\"bin/.*$marker\|\"bin/hw/$marker" "$inventory" ||
			die "modem inventory lacks component: $marker"
	done
	for family in uim pdc-mbn radio-nas data sms voice ims ssr; do
		grep -q "\"$family\"" "$inventory" ||
			die "modem inventory lacks symbol family: $family"
	done
	grep -q 'hotdog-radio-bootstrapd' "$evidence" ||
		die "modem architecture lacks the pre-online owner"
	grep -q 'hotdog-imsd' "$evidence" ||
		die "modem architecture lacks the IMS owner"
	grep -q 'profiles_unique_casefold' "$firmware_inventory" ||
		die "modem firmware inventory lacks duplicate-safe MCFG counts"
	grep -q 'bundle_sha256' "$firmware_inventory" ||
		die "modem firmware inventory lacks source identity"
}

validate_hotdog_radio_state_contract() {
	local source_dir="helpers/hotdog-radio"
	local glib_flags=""
	local qmi_flags=""
	local supervisor_flags=""
	local output=""
	local result=""

	log "Hotdog radio state replay contract"
	for source in hotdog-radio-state.c hotdog-radio-state.h hotdog-radio-replay.c; do
		[ -f "$source_dir/$source" ] || die "missing radio state source: $source"
	done
	for source in hotdog-mbn.c hotdog-mbn.h hotdog-mbn-inspect.c; do
		[ -f "$source_dir/$source" ] || die "missing MBN selector source: $source"
	done
	for source in hotdog-mcfg.c hotdog-mcfg.h hotdog-mcfg-inspect.c; do
		[ -f "$source_dir/$source" ] || die "missing MCFG catalog source: $source"
	done
	for source in hotdog-pdc-load.c hotdog-pdc-load.h hotdog-pdc-load-replay.c \
		      hotdog-qmi-pdc-load.c hotdog-qmi-pdc-load.h; do
		[ -f "$source_dir/$source" ] || die "missing PDC load source: $source"
	done
	for source in hotdog-qmi-pdc-list.c hotdog-qmi-pdc-list.h; do
		[ -f "$source_dir/$source" ] || die "missing PDC catalog transport source: $source"
	done
	for source in hotdog-qmi-pdc-dispatch.c hotdog-qmi-pdc-dispatch.h; do
		[ -f "$source_dir/$source" ] || die "missing PDC dispatcher source: $source"
	done
	for source in hotdog-qmi-pdc-backend.c hotdog-qmi-pdc-backend.h; do
		[ -f "$source_dir/$source" ] || die "missing asynchronous PDC backend: $source"
	done
	for source in hotdog-pdc-controller.c hotdog-pdc-controller.h; do
		[ -f "$source_dir/$source" ] || die "missing PDC controller source: $source"
	done
	for source in hotdog-pdc-executor.c hotdog-pdc-executor.h; do
		[ -f "$source_dir/$source" ] || die "missing PDC executor source: $source"
	done
	for source in hotdog-radio-approval.c hotdog-radio-approval.h; do
		[ -f "$source_dir/$source" ] || die "missing radio approval source: $source"
	done
	for source in hotdog-mcfg-runtime.c hotdog-mcfg-runtime.h; do
		[ -f "$source_dir/$source" ] || die "missing MCFG runtime parser: $source"
	done
	for source in hotdog-radio-gate.c hotdog-radio-gate.h; do
		[ -f "$source_dir/$source" ] || die "missing combined radio execution gate: $source"
	done
	for source in hotdog-radio-readiness.c hotdog-radio-readiness.h; do
		[ -f "$source_dir/$source" ] || die "missing radio readiness source: $source"
	done
	for source in hotdog-radio-supervisor.c hotdog-radio-supervisor.h \
		hotdog-radio-supervisor-replay.c hotdog-radio-supervisord.c \
		hotdog-radio-reattest.c hotdog-radio-reattest.h; do
		[ -f "$source_dir/$source" ] || die "missing radio supervisor source: $source"
	done
	for source in hotdog-uim.c hotdog-uim.h hotdog-uim-replay.c; do
		[ -f "$source_dir/$source" ] || die "missing UIM model source: $source"
	done
	for source in hotdog-qmi-uim.c hotdog-qmi-uim.h hotdog-radio-bootstrapd.c; do
		[ -f "$source_dir/$source" ] || die "missing QRTR/UIM transport source: $source"
	done
	grep -q 'observation="/run/hotdog-radio/observation"' \
		"aports/device/testing/hotdog-radio-bootstrap/hotdog-radio-bootstrap.initd" ||
		die "radio observation service publishes a false readiness record"
	grep -q '"/sbin/rc-service", "modemmanager", "start"' \
		"$source_dir/hotdog-radio-bootstrapd.c" ||
		die "verified radio readiness has no explicit ModemManager handoff"
	for source in hotdog-qmi-dms.c hotdog-qmi-dms.h; do
		[ -f "$source_dir/$source" ] || die "missing DMS gate source: $source"
	done
	for source in hotdog-qmi-nas.c hotdog-qmi-nas.h; do
		[ -f "$source_dir/$source" ] || die "missing NAS snapshot source: $source"
	done
	for source in hotdog-qmi-wds.c hotdog-qmi-wds.h; do
		[ -f "$source_dir/$source" ] || die "missing WDS data-plane adapter: $source"
	done
	for source in hotdog-qmi-rmnet.c hotdog-qmi-rmnet.h; do
		[ -f "$source_dir/$source" ] || die "missing QMI rmnet topology adapter: $source"
	done
	for source in hotdog-qmi-ims-session.c hotdog-qmi-ims-session.h; do
		[ -f "$source_dir/$source" ] || die "missing asynchronous IMS WDS session: $source"
	done
	grep -q 'QMI_DATA_ENDPOINT_TYPE_EMBEDDED' "$source_dir/hotdog-qmi-rmnet.c" ||
		die "IPA rmnet topology lacks its embedded QMI endpoint"
	grep -q 'QMI_DEVICE_MUX_ID_MAX' "$source_dir/hotdog-qmi-rmnet.c" ||
		die "rmnet link validation does not bound dynamic mux IDs"
	for call in qmi_device_add_link_with_flags qmi_client_wds_bind_subscription \
		qmi_client_wds_bind_mux_data_port qmi_client_wds_start_network \
		qmi_client_wds_get_current_settings qmi_client_wds_stop_network \
		qmi_device_release_client qmi_device_delete_link; do
		grep -q "$call" "$source_dir/hotdog-qmi-ims-session.c" ||
			die "IMS WDS session lacks transaction operation: $call"
	done
	grep -q 'QMI_WDS_CLIENT_TYPE_UNDEFINED' "$source_dir/hotdog-qmi-ims-session.c" ||
		die "IMS handset session incorrectly identifies as tethering"
	for source in hotdog-qmi-wds-profile.c hotdog-qmi-wds-profile.h; do
		[ -f "$source_dir/$source" ] || die "missing WDS profile transport: $source"
	done
	for source in hotdog-qmi-wds-discovery.c hotdog-qmi-wds-discovery.h; do
		[ -f "$source_dir/$source" ] || die "missing reusable WDS discovery: $source"
	done
	[ -f "$source_dir/hotdog-wds-profile-probe.c" ] ||
		die "missing read-only WDS profile probe"
	grep -q 'hotdog-wds-profile-probe.c' \
		"aports/device/testing/hotdog-radio-bootstrap/APKBUILD" ||
		die "WDS profile probe is not built by the radio package"
	grep -q 'hotdog-qmi-wds-discovery.c' \
		"aports/device/testing/hotdog-radio-bootstrap/APKBUILD" ||
		die "radio package probe omits shared WDS discovery"
	grep -q 'usr/libexec/hotdog-wds-profile-probe' \
		"aports/device/testing/hotdog-radio-bootstrap/APKBUILD" ||
		die "WDS profile probe is not installed by the radio package"
	grep -q 'qmi_message_wds_bind_subscription_input_set_subscription_id' \
		"$source_dir/hotdog-qmi-wds-profile.c" ||
		die "WDS profile transport does not bind a modem subscription"
	for getter in get_apn_name get_pdp_type get_apn_type_mask \
		get_pcscf_address_using_pco; do
		grep -q "$getter" "$source_dir/hotdog-qmi-wds-profile.c" ||
			die "WDS profile transport lacks required profile evidence: $getter"
	done
	if grep -Eq 'get_(username|password)' "$source_dir/hotdog-qmi-wds-profile.c"; then
		die "WDS profile discovery must not read APN credentials"
	fi
	if grep -Eqi 'start_network|stop_network|QMI_SERVICE_UIM|add_link' \
		"$source_dir/hotdog-wds-profile-probe.c"; then
		die "read-only WDS profile probe contains a mutating modem operation"
	fi
	grep -q 'hotdog_qmi_wds_discovery_start' \
		"$source_dir/hotdog-wds-profile-probe.c" ||
		die "diagnostic probe diverges from daemon WDS discovery"
	grep -q 'discovery->result = -EUCLEAN' \
		"$source_dir/hotdog-qmi-wds-discovery.c" ||
		die "WDS discovery hides a failed CID release"
	for source in hotdog-network.c hotdog-network.h \
		hotdog-ims-bearer.c hotdog-ims-bearer.h \
		hotdog-ims-executor.c hotdog-ims-executor.h \
		hotdog-ims-bearer-state.c hotdog-ims-bearer-state.h \
		hotdog-ims-netconfig.c hotdog-ims-netconfig.h; do
		[ -f "$source_dir/$source" ] || die "missing IMS bearer model: $source"
	done
	grep -q 'HOTDOG_APN_TYPE_IMS' "$source_dir/hotdog-ims-bearer.h" ||
		die "IMS bearer model does not identify IMS profiles by APN type"
	grep -q 'purpose != HOTDOG_BEARER_DEFAULT' "$source_dir/hotdog-network.c" ||
		die "dedicated IMS bearers are incorrectly tied to DDS switching"
	grep -q 'QMI_WDS_REQUESTED_SETTINGS_PCSCF_SERVER_ADDRESS_LIST' \
		"$source_dir/hotdog-qmi-wds.c" ||
		die "WDS Current Settings do not request P-CSCF routing evidence"
	grep -q 'purpose == HOTDOG_BEARER_IMS' "$source_dir/hotdog-network.c" ||
		die "IMS connected state does not require P-CSCF routing evidence"
	grep -q 'HOTDOG_IMS_EXECUTOR_BLOCKED' "$source_dir/hotdog-ims-executor.c" ||
		die "IMS executor does not preserve unresolved rollback residue"
	grep -q 'HOTDOG_IMS_EXECUTOR_ACTION_RELEASE_CLIENTS' \
		"$source_dir/hotdog-ims-executor.c" ||
		die "IMS executor does not release WDS clients during rollback"
	grep -q 'HOTDOG_IMS_EXECUTOR_ACTION_UNCONFIGURE_LINK' \
		"$source_dir/hotdog-ims-executor.c" ||
		die "IMS executor does not rollback local IP configuration"
	grep -q 'HOTDOG_IMS_BEARER_BLOCKED' "$source_dir/hotdog-ims-bearer-state.c" ||
		die "IMS bearer runtime cannot expose unresolved ownership"
	grep -q 'O_NOFOLLOW' "$source_dir/hotdog-ims-bearer-state.c" ||
		die "IMS bearer runtime state does not reject symlinks"
	grep -q 'HOTDOG_IMS_FWMARK_BASE' "$source_dir/hotdog-ims-netconfig.h" ||
		die "IMS network configuration has no isolated routing mark"
	grep -q 'g_spawn_sync' "$source_dir/hotdog-ims-netconfig.c" ||
		die "IMS network configuration has no argv runner"
	if grep -Eq 'sh[[:space:]]+-c|system\(' "$source_dir/hotdog-ims-netconfig.c"; then
		die "IMS network configuration executes shell text"
	fi
	for source in hotdog-qmi-wms.c hotdog-qmi-wms.h; do
		[ -f "$source_dir/$source" ] || die "missing WMS SMS adapter: $source"
	done
	for source in hotdog-qmi-voice.c hotdog-qmi-voice.h; do
		[ -f "$source_dir/$source" ] || die "missing QMI Voice adapter: $source"
	done
	for source in hotdog-qmi-imsa.c hotdog-qmi-imsa.h; do
		[ -f "$source_dir/$source" ] || die "missing IMSA registration adapter: $source"
	done
	for source in hotdog-ims-state.c hotdog-ims-state.h hotdog-imsd.c; do
		[ -f "$source_dir/$source" ] || die "missing IMS runtime state contract: $source"
	done
	output="$(mktemp)"
	trap 'rm -f "$output"' RETURN
	cc -std=c11 -Wall -Wextra -Werror -O2 -I "$source_dir" \
		"$source_dir/hotdog-radio-state.c" "$source_dir/hotdog-radio-replay.c" \
		-o "$output"
	result="$(printf '%s\n' \
		'QRTR_UP' 'UIM_READY 1 1' 'PDC_STATUS 1 0' 'DMS_ONLINE' \
		'NAS_REGISTERED' 'DATA_UP' 'SMS_BEGIN' 'CALL_BEGIN' \
		'IMS_REGISTERED' 'QRTR_DOWN' | "$output")"
	printf '%s\n' "$result" | grep -q 'phase=ready result=0 actions=publish-ready' ||
		die "radio replay does not reach ready"
	for action in teardown-data fail-sms drop-calls clear-ims; do
		printf '%s\n' "$result" | tail -n 1 | grep -q "$action" ||
			die "radio SSR replay lacks action: $action"
	done
	cc -std=c11 -Wall -Wextra -Werror -O2 -I "$source_dir" \
		"$source_dir/hotdog-mbn.c" "$source_dir/hotdog-mbn-inspect.c" \
		-o "$output"
	glib_flags="$(pkg-config --cflags --libs glib-2.0)"
	# shellcheck disable=SC2086
	cc -std=c11 -Wall -Wextra -Werror -O2 -I "$source_dir" \
		"$source_dir/hotdog-mbn.c" "$source_dir/hotdog-pdc.c" \
		"$source_dir/hotdog-mcfg.c" "$source_dir/hotdog-mcfg-inspect.c" \
		$glib_flags -o "$output"
	cc -std=c11 -Wall -Wextra -Werror -O2 -I "$source_dir" \
		"$source_dir/hotdog-pdc-load.c" "$source_dir/hotdog-pdc-load-replay.c" \
		-o "$output"
	qmi_flags="$(pkg-config --cflags qmi-glib glib-2.0)"
	# shellcheck disable=SC2086
	cc -std=c11 -Wall -Wextra -Werror -O2 -fsyntax-only -I "$source_dir" \
		"$source_dir/hotdog-qmi-pdc-load.c" $qmi_flags
	cc -std=c11 -Wall -Wextra -Werror -O2 -I "$source_dir" \
		"$source_dir/hotdog-uim.c" "$source_dir/hotdog-uim-replay.c" \
		-o "$output"
	supervisor_flags="$(pkg-config --cflags --libs qrtr-glib gio-2.0 glib-2.0)"
	# shellcheck disable=SC2086
	cc -std=c11 -Wall -Wextra -Werror -O2 -I "$source_dir" \
		"$source_dir/hotdog-radio-supervisord.c" \
		"$source_dir/hotdog-radio-supervisor.c" \
		"$source_dir/hotdog-radio-reattest.c" \
		"$source_dir/hotdog-radio-readiness.c" \
		"$source_dir/hotdog-mcfg-runtime.c" "$source_dir/hotdog-pdc.c" \
		"$source_dir/hotdog-uim.c" "$source_dir/hotdog-mbn.c" \
		$supervisor_flags -o "$output"
	rm -f "$output"
	trap - RETURN
}

validate_hotdog_oos10_modem_contract() {
	local device_apkbuild="aports/device/testing/device-oneplus-hotdog/APKBUILD"
	local firmware_dir="aports/device/testing/firmware-oneplus-hotdog-modem-oos10"
	local firmware_apkbuild="$firmware_dir/APKBUILD"
	local private_blob="$firmware_dir/modem-oos10.0.13.mbn"
	local private_mcfg="$firmware_dir/mcfg-oos10.0.13.tar.gz"
	local stage_helper="scripts/stage-private-modem-firmware.sh"
	local sim_helper="helpers/hotdog-sim-slot2-check.sh"

	log "Hotdog OxygenOS 10 modem firmware contract"
	[ -f "$firmware_apkbuild" ] || die "missing OOS10 modem firmware APKBUILD"
	[ -f "$firmware_dir/README.md" ] || die "missing OOS10 modem firmware provenance"
	[ -f "$firmware_dir/mcfg-manifest.txt" ] || die "missing OOS10 MCFG runtime manifest"
	[ -x "$stage_helper" ] || die "missing executable OOS10 modem stage helper"
	[ -x "$sim_helper" ] || die "missing executable guarded SIM slot 2 helper"
	grep -q '^[[:space:]]*firmware-oneplus-hotdog-modem-oos10$' "$device_apkbuild" ||
		die "Hotdog device does not select the OOS10 modem firmware"
	if grep -q '^[[:space:]]*firmware-oneplus-hotdog-modem$' "$device_apkbuild"; then
		die "Hotdog device still selects the OOS12 modem firmware"
	fi
	grep -q '559a517c2d4ca5c22d25e0a9b3383bbf7591a632f688b629a19c3e51e3dba9e5' "$stage_helper" ||
		die "OOS10 modem stage helper lacks the output hash gate"
	grep -q '7920f87d8544d17efbe93ec9d7365190a43016eb9d286b1361de5fc96ca6a7b9' "$stage_helper" ||
		die "OOS10 modem stage helper lacks the source hash gate"
	grep -q 'a81d9d110cd2aa9ecc906ec69c1698aaf4518142f890fa6f6d8e656e498ff1fa' "$stage_helper" ||
		die "OOS10 modem stage helper lacks the MCFG hash gate"
	grep -q '/usr/share/hotdog-radio/mcfg/mcfg_sw/' "$firmware_apkbuild" ||
		die "OOS10 modem package does not install the MCFG catalog"
	grep -q '/usr/share/hotdog-radio/mcfg/MANIFEST' "$firmware_apkbuild" ||
		die "OOS10 modem package does not install the MCFG manifest"
	grep -q '^profile-count=69$' "$firmware_dir/mcfg-manifest.txt" ||
		die "OOS10 MCFG manifest has the wrong profile count"
	grep -q '^catalog-file-count=143$' "$firmware_dir/mcfg-manifest.txt" ||
		die "OOS10 MCFG manifest has the wrong file count"
	grep -q 'expected_modem_sha=559a517c' "$sim_helper" ||
		die "SIM helper does not attest the OOS10 modem firmware"
	grep -q 'PIN1 retries are' "$sim_helper" ||
		die "SIM helper does not fail closed on retry changes"
	if git ls-files --error-unmatch "$private_blob" >/dev/null 2>&1; then
		die "private OOS10 modem firmware is tracked by Git"
	fi
	if git ls-files --error-unmatch "$private_mcfg" >/dev/null 2>&1; then
		die "private OOS10 MCFG catalog is tracked by Git"
	fi
}

validate_hotdog_plasma_apps_contract() {
	local device_apkbuild="aports/device/testing/device-oneplus-hotdog/APKBUILD"
	local powerdevil_config="aports/device/testing/device-oneplus-hotdog/powerdevilrc"
	local inhibitor_service="aports/device/testing/device-oneplus-hotdog/hotdog-no-sleep.initd"
	local inhibitor_install="aports/device/testing/device-oneplus-hotdog/device-oneplus-hotdog-plasma-mobile-apps.post-install"
	local session_policy="aports/device/testing/device-oneplus-hotdog/hotdog-plasma-no-sleep"
	local session_autostart="aports/device/testing/device-oneplus-hotdog/hotdog-plasma-no-sleep.desktop"
	local package=""

	log "hotdog Plasma Mobile application contract"
	grep -q '\$pkgname-plasma-mobile-apps:plasma_mobile_apps' "$device_apkbuild" ||
		die "device package lacks the Plasma Mobile application subpackage"
	grep -q 'install_if="\$pkgname=\$pkgver-r\$pkgrel postmarketos-ui-plasma-mobile"' \
		"$device_apkbuild" || die "mobile applications are not gated on Plasma Mobile"
	for package in \
		angelfish discover discover-backend-flatpak dolphin flatpak kalk kclock \
		koko konsole kweather megapixels merkuro okular-mobile plasma-dialer \
		polkit-elogind spacebar xdg-user-dirs; do
		grep -q "^[[:space:]]*$package$" "$device_apkbuild" ||
			die "missing Plasma Mobile application dependency: $package"
	done
	grep -q '"$subpkgdir/etc/xdg/powerdevilrc"' "$device_apkbuild" ||
		die "Plasma Mobile subpackage does not install the PowerDevil defaults"
	grep -q '"$subpkgdir/etc/init.d/hotdog-no-sleep"' "$device_apkbuild" ||
		die "Plasma Mobile subpackage does not install the suspend inhibitor"
	grep -q '"$subpkgdir/usr/libexec/hotdog-plasma-no-sleep"' "$device_apkbuild" ||
		die "Plasma Mobile subpackage does not install the session policy"
	grep -q '"$subpkgdir/etc/xdg/autostart/hotdog-plasma-no-sleep.desktop"' \
		"$device_apkbuild" || die "Plasma Mobile subpackage does not autostart the session policy"
	[ -f "$powerdevil_config" ] ||
		die "missing PowerDevil defaults: $powerdevil_config"
	[ -f "$inhibitor_service" ] ||
		die "missing suspend inhibitor: $inhibitor_service"
	[ -f "$inhibitor_install" ] ||
		die "missing suspend inhibitor post-install script: $inhibitor_install"
	[ -f "$session_policy" ] || die "missing Plasma session policy: $session_policy"
	[ -f "$session_autostart" ] || die "missing Plasma session autostart: $session_autostart"
	for profile in AC Battery LowBattery; do
		grep -Fq "[$profile][SuspendAndShutdown]" "$powerdevil_config" ||
			die "PowerDevil defaults lack the $profile suspend group"
		grep -Fq "[$profile][DisplayAndBrightness]" "$powerdevil_config" ||
			die "PowerDevil defaults lack the $profile display group"
	done
	[ "$(grep -c '^AutoSuspendAction=0$' "$powerdevil_config")" -eq 3 ] ||
		die "automatic suspend must be disabled for all three PowerDevil profiles"
	[ "$(grep -c '^TurnOffDisplayWhenIdle=true$' "$powerdevil_config")" -eq 6 ] ||
		die "display blanking must be enabled for all three PowerDevil profiles"
	[ "$(grep -c '^TurnOffDisplayIdleTimeoutSec=120$' "$powerdevil_config")" -eq 6 ] ||
		die "display blanking must use the validated two-minute timeout"
	grep -q -- '--key Autolock false$' "$session_policy" ||
		die "automatic screen locking must be disabled"
	grep -q -- '--key LockOnResume false$' "$session_policy" ||
		die "screen locking on resume must be disabled"
	grep -q '^command="/usr/bin/elogind-inhibit"$' "$inhibitor_service" ||
		die "suspend inhibitor does not invoke elogind-inhibit"
	grep -q '^command_args="--what=sleep ' "$inhibitor_service" ||
		die "suspend inhibitor must block sleep without blocking display idle"
	grep -q '^rc-update add hotdog-no-sleep default$' "$inhibitor_install" ||
		die "Plasma Mobile package does not enable the suspend inhibitor"
}

validate_hotdog_ucm_contract() {
	local aport_dir="aports/device/testing/device-oneplus-hotdog"
	local apkbuild="$aport_dir/APKBUILD"
	local master="$aport_dir/hotdog.conf"
	local hifi="$aport_dir/HiFi.conf"
	local expected

	log "hotdog speaker and microphone UCM contract"
	grep -q '^[[:space:]]*alsa-ucm-conf$' "$apkbuild" ||
		die "device package does not depend on alsa-ucm-conf"
	for input in HiFi.conf hotdog.conf; do
		grep -q "^[[:space:]]*$input$" "$apkbuild" ||
			die "device package does not source $input"
		expected="$(awk -v file="$input" '$2 == file { print $1 }' "$apkbuild")"
		[[ "$expected" =~ ^[0-9a-f]{128}$ ]] ||
			die "device package has no unique SHA512 for $input"
		verify_sha512 "$expected" "$aport_dir/$input"
	done

	grep -Fq 'File "/OnePlus/hotdog/HiFi.conf"' "$master" ||
		die "hotdog UCM master does not select the packaged HiFi profile"
	grep -Fq 'SectionDevice."Speaker"' "$hifi" ||
		die "hotdog UCM profile does not expose the internal speakers"
	grep -Fq 'SectionDevice."Mic"' "$hifi" ||
		die "hotdog UCM profile does not expose the internal microphone"
	grep -Fq 'PlaybackPCM "hw:${CardId},0"' "$hifi" ||
		die "hotdog UCM profile does not select MultiMedia1"
	grep -Fq 'CapturePCM "hw:${CardId},1"' "$hifi" ||
		die "hotdog UCM profile does not select MultiMedia2"
	grep -Fq "cset \"name='QUAT_MI2S_RX Audio Mixer MultiMedia1' 1\"" "$hifi" ||
		die "hotdog UCM profile does not enable the validated speaker route"
	grep -Fq "cset \"name='QUAT_MI2S_RX Audio Mixer MultiMedia1' 0\"" "$hifi" ||
		die "hotdog UCM profile does not disable the validated speaker route"
	for control in \
		"cset \"name='AMIC4_5 SEL' AMIC4\"" \
		"cset \"name='CDC_IF TX0 MUX' DEC0\"" \
		"cset \"name='AIF1_CAP Mixer SLIM TX0' 1\"" \
		"cset \"name='MultiMedia2 Mixer SLIMBUS_0_TX' 1\"" \
		"cset \"name='MultiMedia2 Mixer SLIMBUS_0_TX' 0\"" \
		"cset \"name='AIF1_CAP Mixer SLIM TX0' 0\"" \
		"cset \"name='CDC_IF TX0 MUX' ZERO\"" \
		"cset \"name='ADC MUX0' AMIC\"" \
		"cset \"name='AMIC MUX0' ADC4\"" \
		"cset \"name='ADC4 Volume' 20\"" \
		"cset \"name='DEC0 Volume' 96\"" \
		"cset \"name='AMIC MUX0' ZERO\"" \
		"cset \"name='ADC4 Volume' 0\"" \
		"cset \"name='DEC0 Volume' 84\""; do
		grep -Fq "$control" "$hifi" ||
			die "hotdog UCM profile lacks validated mixer control: $control"
	done
	grep -Fq '"$pkgdir/usr/share/alsa/ucm2/OnePlus/hotdog/HiFi.conf"' "$apkbuild" ||
		die "device package does not install the hotdog HiFi profile"
	grep -Fq '"$pkgdir/usr/share/alsa/ucm2/conf.d/sm8150/OnePlus 7T Pro.conf"' \
		"$apkbuild" || die "device package does not install the hotdog UCM card mapping"
}

validate_hotdog_avb_contract() {
	local aport_dir="aports/device/testing/device-oneplus-hotdog"
	local apkbuild="$aport_dir/APKBUILD"
	local deviceinfo="$aport_dir/deviceinfo"
	local hook="$aport_dir/postprocess-boot-avb.sh"
	local expected

	log "hotdog deterministic AVB boot-image contract"
	[ -x "$hook" ] || die "missing executable hotdog AVB postprocess hook"
	sh -n "$hook"
	shellcheck --severity=warning --shell=sh -- "$hook"

	grep -Fqx \
		'deviceinfo_mkinitfs_postprocess="/usr/share/mkinitfs/postprocess-oneplus-hotdog-boot-avb.sh"' \
		"$deviceinfo" || die "deviceinfo does not select the hotdog AVB hook"
	grep -q '^[[:space:]]*android-tools-avbtool$' "$apkbuild" ||
		die "device package does not depend on android-tools-avbtool"
	grep -q '^[[:space:]]*postprocess-boot-avb[.]sh$' "$apkbuild" ||
		die "device package does not source the hotdog AVB hook"
	grep -Fq '"$pkgdir/usr/share/mkinitfs/postprocess-oneplus-hotdog-boot-avb.sh"' \
		"$apkbuild" || die "device package does not install the hotdog AVB hook"

	expected="$(awk '$2 == "postprocess-boot-avb.sh" { print $1 }' "$apkbuild")"
	[[ "$expected" =~ ^[0-9a-f]{128}$ ]] ||
		die "device package has no unique SHA512 for the hotdog AVB hook"
	verify_sha512 "$expected" "$hook"

	grep -Fq 'partition_size=100663296' "$hook" ||
		die "hotdog AVB hook does not pin the 96 MiB boot partition"
	grep -Fq -- '--partition_name boot' "$hook" ||
		die "hotdog AVB hook does not target the boot partition"
	grep -Fq -- '--algorithm NONE' "$hook" ||
		die "hotdog AVB hook does not use the accepted algorithm"
	grep -Fq -- '--salt "$raw_sha"' "$hook" ||
		die "hotdog AVB hook salt is not derived from the raw image digest"
	grep -Fq 'avbtool verify_image --image "$boot_image"' "$hook" ||
		die "hotdog AVB hook does not verify its result"
}

validate_rescue_supervisor_source() {
	local source="helpers/hotdog-rescue-supervisor.c"
	local builder="scripts/build-hotdog-rescue-supervisor.sh"
	local initramfs_builder="scripts/build-mainline-pmos-wrapper-initramfs.sh"
	local dtb_builder="scripts/build-mainline-pmos-boot-dtb.sh"

	[ -f "$source" ] || die "missing rescue supervisor source: $source"
	[ -x "$builder" ] || die "missing executable rescue supervisor builder: $builder"
	[ -x "$initramfs_builder" ] ||
		die "missing executable initramfs builder: $initramfs_builder"
	[ -x "$dtb_builder" ] ||
		die "missing executable mainline boot DTB builder: $dtb_builder"

	log "static rescue supervisor source contract"
	cc -std=c11 -Wall -Wextra -Werror -fsyntax-only "$source"
	grep -q 'HOTDOG_RESCUE_SUPERVISOR_V1' "$source" ||
		die "rescue supervisor identity marker is missing"
	grep -q 'CLOCK_MONOTONIC' "$source" ||
		die "rescue supervisor does not use a monotonic clock"
	grep -q 'LINUX_REBOOT_CMD_RESTART2' "$source" ||
		die "rescue supervisor lacks RESTART2"
	grep -q 'RESTART_REASON_BOOTLOADER' "$source" ||
		die "rescue supervisor lacks the bootloader restart reason"
	grep -q 'WDT_TIMEOUT_SEC 32U' "$source" ||
		die "rescue supervisor APSS fallback is not bounded to 32 seconds"
	grep -q 'WATCHDOG_PATH "/dev/watchdog0"' "$source" ||
		die "rescue supervisor does not prefer the Linux watchdog device"
	grep -q 'WDIOC_SETTIMEOUT' "$source" ||
		die "rescue supervisor does not bound the Linux watchdog timeout"
	if grep -Eq '(^|[^[:alnum:]_])sync[[:space:]]*\(' "$source"; then
		die "rescue supervisor deadline path must not block in sync()"
	fi

	grep -q 'zig cc -target aarch64-linux-musl -static' "$builder" ||
		die "rescue supervisor builder does not pin a static AArch64 target"
	grep -q 'qemu-aarch64 "$OUTPUT" --self-test' "$builder" ||
		die "rescue supervisor builder lacks its QEMU self-test"
	grep -q -- '--rescue-supervisor FILE' "$initramfs_builder" ||
		die "initramfs builder does not document --rescue-supervisor"
	grep -q 'hotdog-rescue-supervisor' "$initramfs_builder" ||
		die "initramfs builder does not package the rescue supervisor"
	grep -q 'mode-bootloader 2' "$dtb_builder" ||
		die "mainline boot DTB builder lacks the PM8150 Fastboot mode"
	grep -q 'mode-recovery 1' "$dtb_builder" ||
		die "mainline boot DTB builder lacks the PM8150 recovery mode"
}

validate_bounded_exec_source() {
	local source="helpers/hotdog-bounded-exec.c"
	local builder="scripts/build-hotdog-bounded-exec.sh"
	local initramfs_builder="scripts/build-mainline-pmos-wrapper-initramfs.sh"

	[ -f "$source" ] || die "missing bounded exec source: $source"
	[ -x "$builder" ] || die "missing executable bounded exec builder: $builder"
	[ -x "$initramfs_builder" ] ||
		die "missing executable initramfs builder: $initramfs_builder"

	log "static bounded exec source contract"
	cc -std=c11 -Wall -Wextra -Werror -fsyntax-only "$source"
	grep -q 'HOTDOG_BOUNDED_EXEC_V1' "$source" ||
		die "bounded exec identity marker is missing"
	grep -q 'CLOCK_MONOTONIC' "$source" ||
		die "bounded exec does not use a monotonic clock"
	grep -q 'pid = fork()' "$source" ||
		die "bounded exec does not use fork"
	if grep -Eq '(^|[^[:alnum:]_])vfork[[:space:]]*\(' "$source"; then
		die "bounded exec must not use vfork"
	fi
	grep -q 'execvp(command\[0\], command)' "$source" ||
		die "bounded exec does not execute the requested command"
	grep -q 'kill(-pid, SIGTERM)' "$source" ||
		die "bounded exec does not terminate the child process group"
	grep -q 'kill(-pid, SIGKILL)' "$source" ||
		die "bounded exec lacks its forced termination fallback"
	grep -q 'return 124' "$source" ||
		die "bounded exec lacks the timeout status contract"

	grep -q 'zig cc -target aarch64-linux-musl -static' "$builder" ||
		die "bounded exec builder does not pin a static AArch64 target"
	grep -q 'qemu-aarch64 "$OUTPUT" --self-test' "$builder" ||
		die "bounded exec builder lacks its QEMU self-test"
	grep -q 'expect_status 0 --timeout 2 -- /bin/true' "$builder" ||
		die "bounded exec builder does not test command success"
	grep -q 'expect_status 37 --timeout 2 -- /bin/sh' "$builder" ||
		die "bounded exec builder does not test exit propagation"
	grep -q 'expect_status 124 --timeout 1 -- /bin/sleep 30' "$builder" ||
		die "bounded exec builder does not test a real timeout"
	grep -q -- '--bounded-exec-helper FILE' "$initramfs_builder" ||
		die "initramfs builder does not document --bounded-exec-helper"
	grep -q 'file /hotdog-bounded-exec' "$initramfs_builder" ||
		die "initramfs builder does not package bounded exec"
	grep -q '/hotdog-bounded-exec --timeout 15 -- "$@"' "$initramfs_builder" ||
		die "bounded udev does not invoke the static helper"
	grep -q 'udev-skip' "$initramfs_builder" ||
		die "initramfs builder lacks the diagnostic udev bypass"
	grep -q 'usb-probe' "$initramfs_builder" ||
		die "initramfs builder lacks USB prerequisite tracing"
	grep -q 'dwc3-probe' "$initramfs_builder" ||
		die "initramfs builder lacks DWC3 binding tracing"
	grep -q 'profile retained setup_udev' "$initramfs_builder" ||
		die "diagnostic udev bypass lacks its negative setup_udev guard"
}

validate_disabled_r6_ufs_probe() {
	local source="helpers/r6-ufs-regdump/hotdog_r6_ufs_regdump.c"
	local readme="helpers/r6-ufs-regdump/README.md"

	[ -f "$source" ] || die "missing disabled R6 UFS probe source: $source"
	[ -f "$readme" ] || die "missing disabled R6 UFS probe documentation: $readme"

	log "disabled R6 UFS live-probe contract"
	grep -q 'HOTDOG_R6_UFS_REGDUMP_DISABLED' "$source" ||
		die "R6 UFS probe lacks its disabled marker"
	grep -q 'return -EPERM;' "$source" ||
		die "R6 UFS probe does not fail closed"
	if grep -Eq 'ufshcd_hold[[:space:]]*\(|ufshcd_dme_get[[:space:]]*\(|readl(_relaxed)?[[:space:]]*\(' "$source"; then
		die "R6 UFS probe source contains a live controller access"
	fi
	grep -q '2100b2c93190fdbfbdb61b8ef2d77b5dfc5b6378c13eacc898591fb1ce00396f' "$readme" ||
		die "R6 UFS probe documentation lacks the unsafe binary identity"
}

validate_ramoops_extractor() {
	local extractor="scripts/extract-ramoops-console.py"

	[ -x "$extractor" ] || die "missing executable ramoops extractor: $extractor"
	log "mixed-size ramoops extraction"
	python3 - "$extractor" <<'PY'
import pathlib
import struct
import subprocess
import sys
import tempfile

extractor = pathlib.Path(sys.argv[1]).resolve()
signature = 0x43474244
header_size = 12
zone_size = 0x1000
capacity = zone_size - header_size
reservation = bytearray(0x5000)

stored = b"ABCDE" + b"K" * (capacity - 5)
reservation[0x3000:0x3000 + header_size] = struct.pack(
    "<III", signature, 5, capacity
)
reservation[0x3000 + header_size:0x4000] = stored

pmsg = b"stage-two-pmsg\n"
reservation[0x4000:0x4000 + header_size] = struct.pack(
    "<III", signature, 0, len(pmsg)
)
reservation[0x4000 + header_size:0x4000 + header_size + len(pmsg)] = pmsg

with tempfile.NamedTemporaryFile() as image:
    image.write(reservation)
    image.flush()
    result = subprocess.run(
        [
            sys.executable,
            str(extractor),
            "--ddr-phys-base", "0",
            "--reservation-phys", "0",
            "--reservation-size", hex(len(reservation)),
            "--scan-reservation",
            image.name,
        ],
        check=True,
        stdout=subprocess.PIPE,
    )

expected_ring = stored[5:] + stored[:5]
assert b"RAMOOPS_ZONE offset=0x3000 bytes=4084" in result.stdout
assert expected_ring in result.stdout
assert b"RAMOOPS_ZONE offset=0x4000 bytes=15" in result.stdout
assert pmsg in result.stdout
PY
}

main() {
	local command_name

	for command_name in bash cc cmp find git python3 sha512sum shellcheck sort; do
		require_command "$command_name"
	done

	cd -- "$REPO_ROOT"
	git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a Git work tree: $REPO_ROOT"

	validate_shell_scripts
	validate_python_syntax
	validate_markdown_links
	validate_public_markers
	validate_k1_patch_copies
	validate_k1_aport_inputs
	validate_mainline616_aport_inputs
	validate_hotdog_wifi_package_contract
	validate_modemmanager_slot_pin_contract
	validate_libqmi_pdc_subscription_contract
	validate_oxygenos_modem_inventory_contract
	validate_hotdog_radio_state_contract
	validate_hotdog_oos10_modem_contract
	validate_hotdog_plasma_apps_contract
	validate_hotdog_ucm_contract
	validate_hotdog_avb_contract
	validate_rescue_supervisor_source
	validate_bounded_exec_source
	validate_disabled_r6_ufs_probe
	validate_ramoops_extractor

	log "all checks passed"
}

main "$@"
