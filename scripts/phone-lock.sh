#!/usr/bin/env bash

PHONE_LOCK_DIR="${PHONE_LOCK_DIR:-$HOTDOG_LOG_ROOT/phone-operation.lock}"
PHONE_LOCK_HELD="${PHONE_LOCK_HELD:-0}"

phone_lock_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$*"
  else
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
  fi
}

phone_lock_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

phone_lock_owner_pid() {
  if [ -s "$PHONE_LOCK_DIR/pid" ]; then
    sed -n '1p' "$PHONE_LOCK_DIR/pid" 2>/dev/null || true
  fi
}

phone_lock_break_if_stale() {
  local pid=""

  [ -d "$PHONE_LOCK_DIR" ] || return 1
  pid="$(phone_lock_owner_pid)"
  if ! phone_lock_pid_alive "$pid"; then
    phone_lock_log "Removing stale phone operation lock: $PHONE_LOCK_DIR"
    rm -rf "$PHONE_LOCK_DIR"
    return 0
  fi
  return 1
}

phone_lock_acquire() {
  local purpose="$1"
  local wait_sec="${2:-0}"
  local deadline=$((SECONDS + wait_sec))
  local owner=""

  while true; do
    if mkdir "$PHONE_LOCK_DIR" 2>/dev/null; then
      PHONE_LOCK_HELD=1
      {
        printf '%s\n' "$$"
        printf 'purpose=%s\n' "$purpose"
        printf 'started=%s\n' "$(date '+%F %T')"
        printf 'command='
        printf '%q ' "$0" "$@"
        printf '\n'
      } > "$PHONE_LOCK_DIR/pid"
      phone_lock_log "Phone operation lock acquired: $purpose"
      return 0
    fi

    phone_lock_break_if_stale && continue

    owner="$(phone_lock_owner_pid)"
    if [ "$wait_sec" -le 0 ] || [ "$SECONDS" -ge "$deadline" ]; then
      phone_lock_log "Phone operation lock is busy${owner:+ by PID $owner}: $PHONE_LOCK_DIR"
      return 1
    fi

    sleep 2
  done
}

phone_lock_release() {
  local owner=""

  [ "${PHONE_LOCK_HELD:-0}" -eq 1 ] || return 0
  owner="$(phone_lock_owner_pid)"
  if [ "$owner" = "$$" ]; then
    rm -rf "$PHONE_LOCK_DIR"
    phone_lock_log "Phone operation lock released"
  fi
  PHONE_LOCK_HELD=0
}
