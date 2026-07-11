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
	local line
	local expected
	local filename
	local checksum_count=0
	local local_count=0
	local tar_count=0

	[ -f "$apkbuild" ] || die "missing K1 APKBUILD: $apkbuild"
	log "K1 aport SHA512 inputs"

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

	[ "$checksum_count" -eq 6 ] || die "expected 6 K1 SHA512 entries, found $checksum_count"
	[ "$tar_count" -eq 1 ] || die "expected one K1 remote source tarball entry, found $tar_count"
	[ "$local_count" -eq 5 ] || die "expected 5 K1 local inputs, found $local_count"
}

main() {
	local command_name

	for command_name in bash cmp find git python3 sha512sum shellcheck sort; do
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

	log "all checks passed"
}

main "$@"
