#!/usr/bin/env bash

PHONE_LOCK_DIR="${PHONE_LOCK_DIR:-$HOTDOG_LOG_ROOT/phone-operation.lock}"
PHONE_LOCK_FILE="${PHONE_LOCK_FILE:-$PHONE_LOCK_DIR.flock}"
PHONE_LOCK_HELD="${PHONE_LOCK_HELD:-0}"
PHONE_LOCK_FD="${PHONE_LOCK_FD:-}"
PHONE_LOCK_INHERITED="${PHONE_LOCK_INHERITED:-0}"

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

phone_lock_close_fd() {
  if [[ "${PHONE_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    flock -u "$PHONE_LOCK_FD" 2>/dev/null || true
    exec {PHONE_LOCK_FD}>&-
  fi
  PHONE_LOCK_FD=""
}

phone_lock_prepare_detached_child() {
  if [[ "${PHONE_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    exec {PHONE_LOCK_FD}>&-
  fi
  PHONE_LOCK_FD=""
  PHONE_LOCK_HELD=0
  PHONE_LOCK_INHERITED=0
}

phone_lock_break_if_stale() {
  local probe_fd=""
  local removed=1

  [ -d "$PHONE_LOCK_DIR" ] || return 1
  command -v flock >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname -- "$PHONE_LOCK_FILE")" || return 1
  exec {probe_fd}> "$PHONE_LOCK_FILE" || return 1
  if flock -n "$probe_fd"; then
    if [ -d "$PHONE_LOCK_DIR" ]; then
      phone_lock_log "Removing stale phone operation metadata: $PHONE_LOCK_DIR"
      rm -rf -- "$PHONE_LOCK_DIR"
      removed=0
    fi
    flock -u "$probe_fd" 2>/dev/null || true
  fi
  exec {probe_fd}>&-
  return "$removed"
}

phone_lock_acquire() {
  local purpose="$1"
  local wait_sec="${2:-0}"
  local owner=""

  if [ "${PHONE_LOCK_HELD:-0}" -eq 1 ]; then
    phone_lock_log "Phone operation lock already held: $purpose"
    return 0
  fi
  command -v flock >/dev/null 2>&1 || {
    phone_lock_log "Missing flock; refusing phone operation"
    return 127
  }
  case "$wait_sec" in
    ''|*[!0-9]*)
      phone_lock_log "Invalid phone lock wait: $wait_sec"
      return 2
      ;;
  esac

  mkdir -p "$(dirname -- "$PHONE_LOCK_FILE")" || return 1
  exec {PHONE_LOCK_FD}> "$PHONE_LOCK_FILE" || return 1
  if [ "$wait_sec" -eq 0 ]; then
    if ! flock -n "$PHONE_LOCK_FD"; then
      owner="$(phone_lock_owner_pid)"
      phone_lock_log "Phone operation lock is busy${owner:+ by PID $owner}: $PHONE_LOCK_DIR"
      phone_lock_close_fd
      return 1
    fi
  elif ! flock -w "$wait_sec" "$PHONE_LOCK_FD"; then
    owner="$(phone_lock_owner_pid)"
    phone_lock_log "Timed out waiting for phone operation lock${owner:+ held by PID $owner}: $PHONE_LOCK_DIR"
    phone_lock_close_fd
    return 1
  fi

  rm -rf -- "$PHONE_LOCK_DIR"
  mkdir "$PHONE_LOCK_DIR" || {
    phone_lock_close_fd
    return 1
  }
  {
    printf '%s\n' "$$"
    printf 'purpose=%s\n' "$purpose"
    printf 'started=%s\n' "$(date '+%F %T')"
    printf 'command='
    printf '%q ' "$0" "$@"
    printf '\n'
    printf 'flock_file=%s\n' "$PHONE_LOCK_FILE"
  } > "$PHONE_LOCK_DIR/pid"

  PHONE_LOCK_HELD=1
  PHONE_LOCK_INHERITED=0
  phone_lock_log "Phone operation lock acquired: $purpose"
}

phone_lock_adopt_fd() {
  local inherited_fd="$1"
  local fd_target=""
  local lock_target=""
  local owner=""

  case "$inherited_fd" in
    ''|*[!0-9]*)
      phone_lock_log "Invalid inherited phone lock fd: $inherited_fd"
      return 2
      ;;
  esac
  [ -e "/proc/$$/fd/$inherited_fd" ] || {
    phone_lock_log "Inherited phone lock fd is not open: $inherited_fd"
    return 2
  }
  fd_target="$(readlink -f "/proc/$$/fd/$inherited_fd" 2>/dev/null || true)"
  lock_target="$(readlink -m "$PHONE_LOCK_FILE")"
  [ "$fd_target" = "$lock_target" ] || {
    phone_lock_log "Inherited fd $inherited_fd does not reference $PHONE_LOCK_FILE"
    return 2
  }
  owner="$(phone_lock_owner_pid)"
  phone_lock_pid_alive "$owner" || {
    phone_lock_log "Inherited phone lock metadata has no live owner"
    return 2
  }
  flock -n "$inherited_fd" || {
    phone_lock_log "Inherited fd $inherited_fd does not carry the phone lock"
    return 2
  }

  PHONE_LOCK_FD="$inherited_fd"
  PHONE_LOCK_HELD=1
  PHONE_LOCK_INHERITED=1
  phone_lock_log "Adopted inherited phone operation lock from PID $owner"
}

phone_lock_release() {
  local owner=""

  [ "${PHONE_LOCK_HELD:-0}" -eq 1 ] || return 0
  if [ "${PHONE_LOCK_INHERITED:-0}" -eq 1 ]; then
    PHONE_LOCK_HELD=0
    PHONE_LOCK_INHERITED=0
    PHONE_LOCK_FD=""
    return 0
  fi

  owner="$(phone_lock_owner_pid)"
  if [ "$owner" = "$$" ]; then
    rm -rf -- "$PHONE_LOCK_DIR"
    phone_lock_log "Phone operation lock released"
  else
    phone_lock_log "Phone operation lock metadata owner changed; leaving it for stale cleanup"
  fi
  phone_lock_close_fd
  PHONE_LOCK_HELD=0
  PHONE_LOCK_INHERITED=0
}
