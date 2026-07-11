#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/env.sh"

LOG_DIR="$HOTDOG_LOG_ROOT/readonly-ssh"

usage() {
  cat <<'USAGE'
Usage:
  hotdog-readonly-ssh.sh basic
  hotdog-readonly-ssh.sh run COMMAND [ARGS...]

Runs read-only inspection commands against the currently booted pmOS system.
This helper intentionally rejects privilege escalation, flash/reboot tools,
shell metacharacters, and write-oriented commands.
USAGE
}

die() {
  echo "hotdog-readonly-ssh: $*" >&2
  exit 2
}

ssh_base() {
  hotdog_require_pmos_password
  sshpass -p "$HOTDOG_PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    "$HOTDOG_PMOS_USER@$HOTDOG_PMOS_HOST" "$@"
}

quote_remote() {
  local out="" word
  for word in "$@"; do
    printf -v word '%q' "$word"
    out+="${word} "
  done
  printf '%s' "${out% }"
}

reject_arg() {
  local arg="$1"
  case "$arg" in
    *";"*|*"&"*|*"|"*|*">"*|*"<"*|*'$'*|*'`'*|*"("*|*")"*|*"{"*|*"}"*|*$'\n'*)
      die "rejected shell metacharacter in argument: $arg"
      ;;
  esac
  case "$arg" in
    /dev/disk/*|/dev/block/*|/dev/mapper/*|/dev/sd*|/dev/mmcblk*|/dev/loop*)
      die "rejected direct block-device path: $arg"
      ;;
  esac
}

allowed_command() {
  case "$1" in
    awk|cat|date|df|dmesg|env|find|free|getconf|grep|head|hostname|id|ip|ls|lsblk|mount|printenv|ps|readlink|realpath|sed|ss|stat|tail|uname|uptime|wc)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_logged() {
  mkdir -p "$LOG_DIR"
  local stamp log cmd
  stamp="$(date +%Y-%m-%d-%H%M%S)"
  log="$LOG_DIR/${stamp}.log"
  cmd="$(quote_remote "$@")"
  {
    printf 'time=%s\n' "$(date --iso-8601=seconds)"
    printf 'host=%s user=%s\n' "$HOTDOG_PMOS_HOST" "$HOTDOG_PMOS_USER"
    printf 'command=%s\n--- output ---\n' "$cmd"
  } > "$log"
  ssh_base "$cmd" 2>&1 | tee -a "$log"
  printf '\n[log] %s\n' "$log"
}

run_basic() {
  run_logged sh -lc 'uname -a; printf "\n--- uptime ---\n"; uptime; printf "\n--- cmdline ---\n"; cat /proc/cmdline; printf "\n--- mounts ---\n"; mount; printf "\n--- df ---\n"; df -h; printf "\n--- ip addr ---\n"; ip addr; printf "\n--- processes ---\n"; ps w'
}

main() {
  [ $# -gt 0 ] || { usage; exit 0; }
  case "$1" in
    -h|--help)
      usage
      ;;
    basic)
      run_basic
      ;;
    run)
      shift
      [ $# -gt 0 ] || die "missing command after run"
      allowed_command "$1" || die "command is not in read-only allowlist: $1"
      local arg
      for arg in "$@"; do
        reject_arg "$arg"
      done
      run_logged "$@"
      ;;
    *)
      die "unknown mode: $1"
      ;;
  esac
}

main "$@"
