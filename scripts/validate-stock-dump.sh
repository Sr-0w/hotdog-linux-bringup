#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/stock-dump-lib.sh"

QUIET=0
MODE="latest"
DUMP_DIR=""

usage() {
  cat <<'USAGE'
Usage: validate-stock-dump.sh [options] [DUMP_DIR]

Validate a stock partition dump without touching the phone.

Options:
  --latest       Scan stock-before-flash and report the newest complete dump.
                 This is the default when DUMP_DIR is omitted.
  --quiet        Print only the selected complete dump path.
  -h, --help     Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --latest)
      MODE="latest"
      ;;
    --quiet)
      QUIET=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [ -z "$DUMP_DIR" ] || {
        echo "Only one DUMP_DIR may be provided" >&2
        usage >&2
        exit 2
      }
      DUMP_DIR="$1"
      MODE="dir"
      ;;
  esac
  shift
done

print_status() {
  local dir="$1"
  local reason=""

  reason="$(stock_dump_incomplete_reason "$dir")"
  if [ "$reason" = "complete" ]; then
    if [ "$QUIET" -eq 1 ]; then
      printf '%s\n' "$dir"
    else
      printf 'OK complete stock dump: %s\n' "$dir"
    fi
    return 0
  fi

  if [ "$QUIET" -eq 0 ]; then
    printf 'INCOMPLETE stock dump: %s\n' "$dir"
    printf 'reason: %s\n' "$reason"
  fi
  return 1
}

main() {
  local dir=""
  local latest_started=""
  local latest_any=""

  case "$MODE" in
    dir)
      print_status "$DUMP_DIR"
      ;;
    latest)
      dir="$(stock_dump_latest_complete || true)"
      if [ -n "$dir" ]; then
        print_status "$dir"
        return $?
      fi

      if [ "$QUIET" -eq 0 ]; then
        printf 'No complete stock dump found under %s\n' "$(stock_dump_root)"
        latest_started="$(stock_dump_latest_started || true)"
        latest_any="$(stock_dump_latest_any || true)"
        if [ -n "$latest_started" ]; then
          printf 'latest started dump: %s\n' "$latest_started"
          printf 'reason: %s\n' "$(stock_dump_incomplete_reason "$latest_started")"
        elif [ -n "$latest_any" ]; then
          printf 'latest watcher directory: %s\n' "$latest_any"
          printf 'reason: %s\n' "$(stock_dump_incomplete_reason "$latest_any")"
        fi
      fi
      return 1
      ;;
  esac
}

main "$@"
