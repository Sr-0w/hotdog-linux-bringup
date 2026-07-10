#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

usage() {
  cat <<'USAGE'
Usage: validate-current-candidates.sh

Validate the locally prepared hotdog boot candidates without using adb,
fastboot, SSH, USB reset, or any phone command.

Checks:
  - current next wrapper image/restore paths resolve and exist
  - current next cmdline keeps the expected console/fbcon/debug args
  - selected Android DTB pack entry 12 contains the hotdog simplefb wiring
  - generated initramfs/rootfs helper scripts pass shell syntax checks
  - secondary splash and fbcon-only candidates still resolve and have entry12
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

log() {
  printf '[validate-current-candidates] %s\n' "$*"
}

fail() {
  printf '[validate-current-candidates] ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [ -f "$path" ] || fail "missing file: $path"
}

expand_hotdog_path() {
  local path="$1"
  path="${path//\$HOTDOG_ROOT/$HOTDOG_ROOT}"
  path="${path//\$HOTDOG_LOG_ROOT/$HOTDOG_LOG_ROOT}"
  printf '%s\n' "$path"
}

wrapper_value() {
  local wrapper="$1"
  local key="$2"
  awk -F'"' -v key="$key" '$0 ~ "^" key "=" { print $2; exit }' "$wrapper"
}

check_cmdline_word() {
  local cmdline="$1"
  local word="$2"
  case " $cmdline " in
    *" $word "*) ;;
    *) fail "cmdline missing expected word: $word" ;;
  esac
}

validate_dtb_entry12() {
  local label="$1"
  local dtb="$2"
  local out

  require_file "$dtb"
  out="$("$HOTDOG_ROOT/scripts/inspect-dtb-pack-simplefb.sh" --dtb "$dtb" --entry 12)"
  printf '%s\n' "$out" > "$tmpdir/${label}-dtb-entry12.txt"
  for key in chosen_node chosen_ranges stdout_path linux_stdout_path simplefb_node simplefb_compatible display0_alias; do
    if ! grep -q "^${key}=yes$" "$tmpdir/${label}-dtb-entry12.txt"; then
      sed -n '1,120p' "$tmpdir/${label}-dtb-entry12.txt" >&2
      fail "$label DTB entry12 missing ${key}=yes"
    fi
  done
  log "$label DTB entry12 simplefb wiring OK"
}

extract_embedded_visible_shell() {
  local postmount="$1"
  local out="$2"

  awk '
    /cat > "\$bin" <<'\''EOF'\''/ {
      in_script = 1
      next
    }
    in_script && /^EOF$/ {
      exit
    }
    in_script {
      print
    }
  ' "$postmount" > "$out"
  [ -s "$out" ] || fail "could not extract embedded hotdog-visible-tty-shell from $postmount"
}

validate_candidate_dir() {
  local label="$1"
  local image="$2"
  local require_buttons="$3"
  local dir="$4"
  local cmdline="$dir/cmdline-watchdog.txt"
  local dtb="$dir/components/dtb"
  local postmount="$dir/initramfs-tree/hotdog_rootfs_postmount.sh"
  local tty_kmsg="$dir/initramfs-tree/hotdog_tty_kmsg_console.sh"
  local watchdog="$dir/initramfs-tree/hotdog_rescue_watchdog.sh"
  local visible_shell="$tmpdir/${label}-hotdog-visible-tty-shell.sh"

  require_file "$image"
  require_file "$cmdline"
  require_file "$dtb"
  log "$label image: $image"
  sha256sum "$image" "$dir/components/kernel" "$dtb" "$dir/components/initramfs-watchdog.gz" \
    | sed "s/^/[validate-current-candidates] ${label} sha256 /"

  validate_dtb_entry12 "$label" "$dtb"

  if [ -f "$postmount" ]; then
    /bin/sh -n "$postmount"
    if grep -q 'cat > "$bin" <<'\''EOF'\''' "$postmount"; then
      extract_embedded_visible_shell "$postmount" "$visible_shell"
      /bin/sh -n "$visible_shell"
      log "$label generated visible tty shell syntax OK"
    elif [ "$require_buttons" = "yes" ]; then
      fail "$label requires embedded hotdog-visible-tty-shell but none was found"
    else
      log "$label rootfs postmount syntax OK"
    fi
  elif [ "$require_buttons" = "yes" ]; then
    fail "$label requires $postmount"
  else
    log "$label has no rootfs postmount helper"
  fi

  if [ -f "$tty_kmsg" ]; then
    /bin/sh -n "$tty_kmsg"
    log "$label tty-kmsg helper syntax OK"
  else
    log "$label has no tty-kmsg helper"
  fi

  if [ "$require_buttons" = "yes" ]; then
    grep -q 'buttons: Vol+ full status' "$visible_shell" || fail "$label visible shell missing button help text"
    grep -q 'monitor_input_device' "$visible_shell" || fail "$label visible shell missing input monitor"
    grep -q 'auto-cycle every 12s' "$visible_shell" || fail "$label visible shell missing auto-cycle status pages"
    grep -q 'usb/watchdog' "$visible_shell" || fail "$label visible shell missing USB/watchdog status block"
    grep -q 'fbcon=vc:1-1' "$cmdline" || fail "$label cmdline missing fbcon=vc:1-1"
    require_file "$watchdog"
    /bin/sh -n "$watchdog"
    grep -q 'HOTDOG_RESCUE_WATCHDOG_SUCCESS_MODE="usb"' "$watchdog" || fail "$label watchdog is not USB-success mode"
    grep -q 'triggering sysrq reboot' "$watchdog" || fail "$label watchdog does not use sysrq reboot first"
    grep -q '/carrier' "$watchdog" || fail "$label watchdog does not require carrier/up USB network state"
    if grep -Fq '/sys/class/udc/*' "$watchdog"; then
      fail "$label watchdog treats a bare UDC controller as USB success"
    fi
    if grep -Fq '/sys/kernel/config/usb_gadget/g1/UDC' "$watchdog"; then
      fail "$label watchdog treats a configfs UDC bind as USB success"
    fi
  fi
}

main() {
  local next_wrapper="$HOTDOG_ROOT/scripts/test-next-lineage414-simplefb-shell.sh"
  local splash_wrapper="$HOTDOG_ROOT/scripts/test-lineage414-splash-ttykmsg.sh"
  local fbcon_wrapper="$HOTDOG_ROOT/scripts/test-lineage414-fbcon-only.sh"
  local image
  local restore
  local dir
  local cmdline

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/hotdog-validate-candidates.XXXXXX")"
  trap 'rm -rf "$tmpdir"' EXIT

  require_file "$next_wrapper"
  image="$(expand_hotdog_path "$(wrapper_value "$next_wrapper" image)")"
  restore="$(expand_hotdog_path "$(wrapper_value "$next_wrapper" restore)")"
  require_file "$image"
  require_file "$restore"
  dir="$(dirname "$image")"
  cmdline="$dir/cmdline-watchdog.txt"
  log "next wrapper: $next_wrapper"
  log "next image: $image"
  log "restore image: $restore"

  check_cmdline_word "$(cat "$cmdline")" "console=tty0"
  check_cmdline_word "$(cat "$cmdline")" "ignore_loglevel"
  check_cmdline_word "$(cat "$cmdline")" "loglevel=8"
  check_cmdline_word "$(cat "$cmdline")" "fbcon=map:0"
  check_cmdline_word "$(cat "$cmdline")" "fbcon=font:VGA8x16"
  check_cmdline_word "$(cat "$cmdline")" "fbcon=vc:1-1"
  check_cmdline_word "$(cat "$cmdline")" "printk.devkmsg=on"
  validate_candidate_dir next "$image" yes "$dir"

  for entry in \
    "secondary_splash:$splash_wrapper:no" \
    "secondary_fbcon:$fbcon_wrapper:no"
  do
    local label="${entry%%:*}"
    local rest="${entry#*:}"
    local wrapper="${rest%%:*}"
    local buttons="${rest##*:}"
    require_file "$wrapper"
    image="$(expand_hotdog_path "$(wrapper_value "$wrapper" image)")"
    restore="$(expand_hotdog_path "$(wrapper_value "$wrapper" restore)")"
    require_file "$image"
    require_file "$restore"
    validate_candidate_dir "$label" "$image" "$buttons" "$(dirname "$image")"
  done

  log "all current candidates validated"
}

tmpdir=""
main "$@"
