#!/usr/bin/env bash

HOTDOG_STOCK_DUMP_PARTITIONS=(
  boot_a
  boot_b
  dtbo_a
  dtbo_b
  vbmeta_a
  vbmeta_b
  recovery_a
  recovery_b
)

stock_dump_root() {
  printf '%s\n' "$HOTDOG_DUMP_ROOT/stock-before-flash"
}

stock_dump_dirs_newest_first() {
  local root
  root="$(stock_dump_root)"
  [ -d "$root" ] || return 0

  find "$root" -maxdepth 1 -type d \
    \( -name '*-recovery-root-blocks' -o -name '*-edl-critical-blocks' \) \
    | sort -r
}

stock_dump_partition_present() {
  local dir="$1"
  local part="$2"
  local path=""

  [ -s "$dir/SHA256SUMS" ] || return 1
  path="$(awk -v part="$part" '
    {
      path=$NF
      if (path ~ "(^|/)block-images/" part "(\\.lun[0-9]+)?\\.img$") {
        print path
        exit
      }
    }
  ' "$dir/SHA256SUMS")"
  [ -n "$path" ] || return 1

  case "$path" in
    /*) [ -s "$path" ] ;;
    *) [ -s "$dir/$path" ] ;;
  esac
}

stock_dump_incomplete_reason() {
  local dir="$1"
  local part

  [ -d "$dir" ] || {
    printf 'missing directory: %s\n' "$dir"
    return 0
  }
  [ -s "$dir/MANIFEST.txt" ] || {
    printf 'missing or empty MANIFEST.txt\n'
    return 0
  }
  [ -s "$dir/run.log" ] || {
    printf 'missing or empty run.log\n'
    return 0
  }
  grep -F "Done: $dir" "$dir/run.log" >/dev/null 2>&1 || {
    printf 'run.log has no matching Done marker\n'
    return 0
  }
  [ -s "$dir/SHA256SUMS" ] || {
    printf 'missing or empty SHA256SUMS\n'
    return 0
  }
  ( cd "$dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || {
    printf 'SHA256SUMS verification failed\n'
    return 0
  }
  case "$dir" in
    *-edl-critical-blocks)
      [ ! -s "$dir/failed-partitions.txt" ] || {
        printf 'EDL failed-partitions.txt is not empty\n'
        return 0
      }
      ;;
  esac
  for part in "${HOTDOG_STOCK_DUMP_PARTITIONS[@]}"; do
    stock_dump_partition_present "$dir" "$part" || {
      printf 'missing or empty partition image: %s\n' "$part"
      return 0
    }
  done

  printf 'complete\n'
}

stock_dump_complete() {
  local dir="$1"
  [ "$(stock_dump_incomplete_reason "$dir")" = "complete" ]
}

stock_dump_started() {
  local dir="$1"

  [ -d "$dir" ] || return 1
  [ -s "$dir/SHA256SUMS" ] && return 0
  find "$dir/block-images" -type f -size +0c ! -name '*.failed' -print -quit 2>/dev/null | grep -q . && return 0
  [ -s "$dir/run.log" ] || return 1
  grep -Eq 'Qualcomm EDL detected|Fastboot device found|ADB shell is root|Dumping |Dumped ' "$dir/run.log"
}

stock_dump_latest_complete() {
  local dir

  while IFS= read -r dir; do
    if stock_dump_complete "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
  done < <(stock_dump_dirs_newest_first)
}

stock_dump_latest_any() {
  stock_dump_dirs_newest_first | head -n 1
}

stock_dump_latest_started() {
  local dir

  while IFS= read -r dir; do
    if stock_dump_started "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
  done < <(stock_dump_dirs_newest_first)
}
