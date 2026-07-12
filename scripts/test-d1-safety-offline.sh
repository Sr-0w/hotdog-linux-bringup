#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/hotdog-d1-safety.XXXXXX)"
MOCK_BIN="$TMP/mock-bin"
SERIAL="SERIAL123"
SOURCE_BOOT_ID="source-boot-id"
SOURCE_KERNEL="4.14.357-openela-perf"
SOURCE_CMDLINE="androidboot.slot_suffix=_b androidboot.serialno=$SERIAL androidboot.project_codename=hotdog androidboot.prjname=19801 androidboot.platform_name=SM8150 androidboot.oplus.brand=OnePlus"
TARGET_BOOT_ID="target-boot-id"
TARGET_KERNEL="6.17.0-sm8150-test"
TARGET_CMDLINE="rdinit=/hotdog-mainline-wrapper androidboot.slot_suffix=_b androidboot.serialno=$SERIAL androidboot.project_codename=hotdog androidboot.prjname=19801 androidboot.platform_name=SM8150 androidboot.oplus.brand=OnePlus"
PASS_COUNT=0

log() {
  printf '[offline-d1] %s\n' "$*"
}

fail() {
  printf '[offline-d1] FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "PASS: $1"
}

kill_case_watchers() {
  local case_dir="$1"
  local pid=""

  case_watcher_pids "$case_dir" > "$case_dir/all-watcher-pids"
  while IFS= read -r pid; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    kill "$pid" 2>/dev/null || true
  done < "$case_dir/all-watcher-pids"
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    wait "$pid" 2>/dev/null || true
  done < "$case_dir/all-watcher-pids"
}

case_watcher_pids() {
  local case_dir="$1"

  {
    [ ! -f "$case_dir/watcher.pids" ] || cat "$case_dir/watcher.pids"
    find "$case_dir/logs" -type f -name 'companion-rescue-watcher-*.pid' -exec cat {} + 2>/dev/null || true
    find "$case_dir/logs" -type f -name 'companion-rescue-watcher-*.ready' \
      -exec sed -n 's/^pid=//p' {} + 2>/dev/null || true
  } | awk '/^[0-9]+$/ && !seen[$0]++'
}

cleanup() {
  local case_dir=""

  trap - EXIT
  for case_dir in "$TMP"/case-*; do
    [ -d "$case_dir" ] || continue
    kill_case_watchers "$case_dir"
  done
  rm -rf -- "$TMP"
}
trap cleanup EXIT

mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/sshpass" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = "-p" ]; then
  shift 2
fi
exec "$@"
MOCK

cat > "$MOCK_BIN/ssh" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ssh %s\n' "$*" >> "$MOCK_STATE_DIR/phone-access.log"
all="$*"
state="$(cat "$MOCK_STATE_DIR/state")"

if [[ "$all" == *"sudo -n sh -c"* ]] && [[ "$all" == *"write-boot-b.sh"* ]]; then
  if [ -n "${KILL_WATCHER_BEFORE_REMOTE_WRITE_PID:-}" ]; then
    kill -KILL "$KILL_WATCHER_BEFORE_REMOTE_WRITE_PID" 2>/dev/null || true
    for _ in {1..100}; do
      kill -0 "$KILL_WATCHER_BEFORE_REMOTE_WRITE_PID" 2>/dev/null || break
      sleep 0.01
    done
    sleep 2
  fi
  printf 'remote-writer\n' >> "$MOCK_STATE_DIR/remote-writer-invocations"
  : > "$MOCK_STATE_DIR/remote-writer-entered"
fi

if [ -n "${KILL_WATCHER_DURING_REMOTE_WRITE_PID:-}" ] &&
  [[ "$all" == *"sudo -n sh -c"* ]] && [[ "$all" == *"write-boot-b.sh"* ]]; then
  kill -KILL "$KILL_WATCHER_DURING_REMOTE_WRITE_PID" 2>/dev/null || true
  for _ in {1..100}; do
    kill -0 "$KILL_WATCHER_DURING_REMOTE_WRITE_PID" 2>/dev/null || break
    sleep 0.01
  done
  sleep 2
fi

if [[ "$all" == *"/proc/sysrq-trigger"* ]]; then
  : > "$MOCK_STATE_DIR/reboot-transport-entered"
  if [ -n "${KILL_WATCHER_BEFORE_REBOOT_PID:-}" ]; then
    kill -KILL "$KILL_WATCHER_BEFORE_REBOOT_PID" 2>/dev/null || true
    for _ in {1..100}; do
      kill -0 "$KILL_WATCHER_BEFORE_REBOOT_PID" 2>/dev/null || break
      sleep 0.01
    done
    sleep 2
  fi
  if [ -n "${KILL_WATCHER_DURING_REBOOT_PID:-}" ]; then
    sleep 0.1
    kill -KILL "$KILL_WATCHER_DURING_REBOOT_PID" 2>/dev/null || true
    for _ in {1..100}; do
      kill -0 "$KILL_WATCHER_DURING_REBOOT_PID" 2>/dev/null || break
      sleep 0.01
    done
    sleep 2
  fi
  if [ "${MOCK_REBOOT_NO_DISPATCH_PROOF:-0}" -ne 1 ] &&
    [[ "$all" =~ HOTDOG_REBOOT_DISPATCH=([0-9a-f]{64}) ]]; then
    printf 'HOTDOG_REBOOT_READY=%s\n' "${BASH_REMATCH[1]}"
    printf 'HOTDOG_REBOOT_DISPATCH=%s\n' "${BASH_REMATCH[1]}"
  fi
  : > "$MOCK_STATE_DIR/reboot-called"
  if [ -n "${MOCK_REBOOT_TARGET_STATE:-}" ]; then
    printf 'reboot-pending:%s\n' "$MOCK_REBOOT_TARGET_STATE" > "$MOCK_STATE_DIR/state"
  else
    printf 'no-usb\n' > "$MOCK_STATE_DIR/state"
  fi
  exit "${MOCK_REBOOT_SSH_STATUS:-255}"
fi

if [ -n "${MUTATE_IMAGE_PATH:-}" ] && [[ "$all" == *"sh -s"* ]] &&
  [ ! -e "$MOCK_STATE_DIR/image-mutated" ]; then
  printf 'mutation' >> "$MUTATE_IMAGE_PATH"
  : > "$MOCK_STATE_DIR/image-mutated"
fi

if [[ "$all" == *"HOTDOG_ATOMIC_IDENTITY_ACK=1"* ]]; then
  case "$state" in
    source)
      boot_id="$SOURCE_BOOT_ID"
      kernel="$SOURCE_KERNEL"
      cmdline="$SOURCE_CMDLINE"
      ;;
    target)
      boot_id="$TARGET_BOOT_ID"
      kernel="$TARGET_KERNEL"
      cmdline="$TARGET_CMDLINE"
      ;;
    *) exit 1 ;;
  esac
  printf 'PMOS_SSH_OK\nPMOS_BOOT_ID=%s\nPMOS_UNAME_R=%s\nPMOS_CMDLINE=%s\n' \
    "$boot_id" "$kernel" "$cmdline"
  if [ "${MOCK_ATOMIC_PEER_FLIP:-0}" -eq 1 ]; then
    : > "$MOCK_STATE_DIR/atomic-peer-flipped"
    printf 'source\n' > "$MOCK_STATE_DIR/state"
    exit 255
  fi
  old_boot_id="${all#*EXPECTED_OLD_BOOT_ID=\'}"
  old_boot_id="${old_boot_id%%\' EXPECTED_KERNEL_PREFIX=*}"
  expected_kernel_prefix="${all#*EXPECTED_KERNEL_PREFIX=\'}"
  expected_kernel_prefix="${expected_kernel_prefix%%\' EXPECTED_CMDLINE_TOKENS=*}"
  expected_tokens="${all#*EXPECTED_CMDLINE_TOKENS=\'}"
  expected_tokens="${expected_tokens%%\' ACK_NONCE=*}"
  [ -z "$old_boot_id" ] || [ "$boot_id" != "$old_boot_id" ] || exit 11
  case "$kernel" in
    "$expected_kernel_prefix"*) ;;
    *) exit 12 ;;
  esac
  while IFS= read -r identity_token; do
    [ -n "$identity_token" ] || continue
    case " $cmdline " in
      *" $identity_token "*) ;;
      *) exit 13 ;;
    esac
  done <<< "$expected_tokens"
  ack_nonce="$(printf '%s\n' "$all" | sed -n "s/.*ACK_NONCE='\([0-9a-f]\{64\}\)'.*/\1/p")"
  [[ "$ack_nonce" =~ ^[0-9a-f]{64}$ ]] || exit 14
  printf 'PMOS_WATCHDOG_ACK=%s\nHOTDOG_ATOMIC_IDENTITY_ACK=ok\n' "$ack_nonce"
  : > "$MOCK_STATE_DIR/atomic-ack-session"
  exit 0
fi

if [[ "$all" == *"PMOS_SSH_OK"* ]]; then
  case "$state" in
    source)
      boot_id="$SOURCE_BOOT_ID"
      kernel="$SOURCE_KERNEL"
      cmdline="$SOURCE_CMDLINE"
      ;;
    target)
      boot_id="$TARGET_BOOT_ID"
      kernel="$TARGET_KERNEL"
      cmdline="$TARGET_CMDLINE"
      ;;
    *) exit 1 ;;
  esac
  printf 'PMOS_SSH_OK\nPMOS_BOOT_ID=%s\nPMOS_UNAME_R=%s\nPMOS_CMDLINE=%s\n' \
    "$boot_id" "$kernel" "$cmdline"
  exit 0
fi

if [[ "$all" == *"hotdog_rescue_watchdog.ok"* ]]; then
  : > "$MOCK_STATE_DIR/legacy-ack-session"
  [ "$state" = "target" ]
  exit
fi

printf 'mock-ssh-ok\n'
MOCK

cat > "$MOCK_BIN/ping" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
state="$(cat "$MOCK_STATE_DIR/state")"
case "$state" in
  source|target|adb-device|recovery) exit 0 ;;
  reboot-pending:*) printf '%s\n' "${state#reboot-pending:}" > "$MOCK_STATE_DIR/state"; exit 1 ;;
  *) exit 1 ;;
esac
MOCK

cat > "$MOCK_BIN/adb" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'adb %s\n' "$*" >> "$MOCK_STATE_DIR/phone-access.log"
state="$(cat "$MOCK_STATE_DIR/state")"
serial="${MOCK_FASTBOOT_SERIAL:-$SERIAL}"
if [ "${1:-}" = "-s" ]; then
  serial="$2"
  shift 2
fi
case "${1:-}" in
  devices)
    printf 'List of devices attached\n'
    case "$state" in
      adb-device) printf '%s\tdevice product:hotdog\n' "$serial" ;;
      recovery) printf '%s\trecovery product:hotdog\n' "$serial" ;;
    esac
    ;;
  reboot)
    if [ "${2:-}" = "bootloader" ]; then
      printf '%s\n' "${MOCK_ADB_BOOTLOADER_STATE:-fastboot}" > "$MOCK_STATE_DIR/state"
    fi
    ;;
esac
MOCK

cat > "$MOCK_BIN/fastboot" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'fastboot %s\n' "$*" >> "$MOCK_STATE_DIR/phone-access.log"
printf '%q ' "$@" >> "$MOCK_STATE_DIR/fastboot.log"
printf '\n' >> "$MOCK_STATE_DIR/fastboot.log"
state="$(cat "$MOCK_STATE_DIR/state")"
serial="${MOCK_FASTBOOT_SERIAL:-$SERIAL}"
product="${MOCK_FASTBOOT_PRODUCT:-msmnile}"
unlocked="${MOCK_FASTBOOT_UNLOCKED:-yes}"
if [ "${1:-}" = "-s" ]; then
  selected="$2"
  shift 2
else
  selected=""
fi
kill_primary_watcher() {
  local watcher_pid=""

  watcher_pid="$(sed -n '1p' "$MOCK_STATE_DIR/watcher.pids")"
  kill -KILL "$watcher_pid" 2>/dev/null || true
  for _ in {1..100}; do
    kill -0 "$watcher_pid" 2>/dev/null || break
    sleep 0.01
  done
  sleep 2
}
case "${1:-}" in
  devices)
    if [ "$state" = "fastboot" ]; then
      printf '%s\tfastboot usb:1-1\n' "$serial"
      [ -z "${MOCK_FASTBOOT_SECOND_SERIAL:-}" ] ||
        printf '%s\tfastboot usb:1-2\n' "$MOCK_FASTBOOT_SECOND_SERIAL"
    fi
    ;;
  getvar)
    var="$2"
    case "$var" in
      serialno) value="${MOCK_FASTBOOT_GETVAR_SERIAL:-$serial}" ;;
      product) value="$product" ;;
      unlocked) value="$unlocked" ;;
      is-userspace)
        if [ -e "$MOCK_STATE_DIR/fastbootd-left" ]; then
          value="no"
        else
          value="${MOCK_FASTBOOT_USERSPACE:-no}"
        fi
        ;;
      current-slot) value="b" ;;
      has-slot:boot) value="yes" ;;
      has-slot:dtbo) value="yes" ;;
      partition-size:boot_b) value="0x6000000" ;;
      partition-size:dtbo_b)
        value="0x1800000"
        if [ -n "${MUTATE_DTBO_PATH:-}" ] && [ ! -e "$MOCK_STATE_DIR/dtbo-mutated" ]; then
          printf 'mutation\n' >> "$MUTATE_DTBO_PATH"
          : > "$MOCK_STATE_DIR/dtbo-mutated"
        fi
        ;;
      slot-retry-count:b) value="7" ;;
      slot-unbootable:b) value="no" ;;
      *) value="unknown" ;;
    esac
    printf '(bootloader) %s: %s\n' "$var" "$value" >&2
    ;;
  flash)
    phase="candidate"
    if [ "$2" = "boot_b" ]; then
      count=0
      [ ! -f "$MOCK_STATE_DIR/boot-flash.count" ] || count="$(cat "$MOCK_STATE_DIR/boot-flash.count")"
      count=$((count + 1))
      printf '%s\n' "$count" > "$MOCK_STATE_DIR/boot-flash.count"
      if [ "$count" -ge 2 ]; then
        phase="restore"
        : > "$MOCK_STATE_DIR/restore-phase"
      fi
    fi
    : > "$MOCK_STATE_DIR/fastboot-$phase-flash-entered"
    if [ "${MOCK_FASTBOOT_KILL_ON:-}" = "$phase-flash" ]; then
      kill_primary_watcher
    fi
    : > "$MOCK_STATE_DIR/fastboot-$phase-flash-dispatched"
    printf 'FLASH %s\n' "$2" >> "$MOCK_STATE_DIR/fastboot-writes.log"
    if [ "$(cat "$MOCK_STATE_DIR/fastboot-behavior")" = "fail" ]; then
      printf 'no-usb\n' > "$MOCK_STATE_DIR/state"
      exit 1
    fi
    ;;
  set_active|--set-active=b)
    phase="candidate"
    [ ! -e "$MOCK_STATE_DIR/restore-phase" ] || phase="restore"
    : > "$MOCK_STATE_DIR/fastboot-$phase-set-active-entered"
    if [ "${MOCK_FASTBOOT_KILL_ON:-}" = "$phase-set-active" ]; then
      kill_primary_watcher
    fi
    : > "$MOCK_STATE_DIR/fastboot-$phase-set-active-dispatched"
    ;;
  reboot)
    if [ "${2:-}" = "bootloader" ] && [ "${MOCK_FASTBOOT_USERSPACE:-no}" = "yes" ] &&
      [ ! -e "$MOCK_STATE_DIR/fastbootd-left" ]; then
      : > "$MOCK_STATE_DIR/fastboot-fastbootd-reboot-entered"
      if [ "${MOCK_FASTBOOT_KILL_ON:-}" = "fastbootd-reboot" ]; then
        kill_primary_watcher
      fi
      : > "$MOCK_STATE_DIR/fastboot-fastbootd-reboot-dispatched"
      : > "$MOCK_STATE_DIR/fastbootd-left"
      printf 'fastboot\n' > "$MOCK_STATE_DIR/state"
      exit 0
    fi
    phase="candidate"
    [ ! -e "$MOCK_STATE_DIR/restore-phase" ] || phase="restore"
    : > "$MOCK_STATE_DIR/fastboot-reboot-transport-entered"
    : > "$MOCK_STATE_DIR/fastboot-$phase-reboot-entered"
    if [ "${MOCK_FASTBOOT_KILL_WATCHER_STAGE:-}" = "before" ]; then
      watcher_pid="$(sed -n '1p' "$MOCK_STATE_DIR/watcher.pids")"
      kill -KILL "$watcher_pid" 2>/dev/null || true
      sleep 2
    elif [ "${MOCK_FASTBOOT_KILL_WATCHER_STAGE:-}" = "during" ]; then
      sleep 0.1
      watcher_pid="$(sed -n '1p' "$MOCK_STATE_DIR/watcher.pids")"
      kill -KILL "$watcher_pid" 2>/dev/null || true
      sleep 2
    fi
    if [ "${MOCK_FASTBOOT_KILL_ON:-}" = "$phase-reboot" ]; then
      kill_primary_watcher
    fi
    : > "$MOCK_STATE_DIR/fastboot-reboot-dispatched"
    : > "$MOCK_STATE_DIR/fastboot-$phase-reboot-dispatched"
    printf '%s\n' "${MOCK_REBOOT_STATE:-source}" > "$MOCK_STATE_DIR/state"
    ;;
esac
[ -z "$selected" ] || [ "$selected" = "$SERIAL" ] || exit 1
MOCK

cat > "$MOCK_BIN/lsusb" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "$(cat "$MOCK_STATE_DIR/state")" = "fastboot" ] &&
  printf 'Bus 001 Device 001: ID 18d1:d00d Android Bootloader Interface\n'
MOCK

cat > "$MOCK_BIN/socat" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK

cat > "$MOCK_BIN/mock-watcher" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
serial=""
restore=""
restore_sha=""
ready=""
nonce=""
challenge_file=""
ack_file=""
boot_b_only=0
ambient_dtbo="${RESTORE_DTBO_IMAGE:-}"
ambient_dtbo_sha="${RESTORE_DTBO_SHA256:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --serial) serial="$2"; shift 2 ;;
    --restore-boot-b) restore="$2"; shift 2 ;;
    --restore-boot-b-sha256) restore_sha="$2"; shift 2 ;;
    --boot-b-only) boot_b_only=1; shift ;;
    --ready-file) ready="$2"; shift 2 ;;
    --contract-nonce) nonce="$2"; shift 2 ;;
    --contract-challenge-file) challenge_file="$2"; shift 2 ;;
    --contract-ack-file) ack_file="$2"; shift 2 ;;
    --after-restore|--timeout|--poll) shift 2 ;;
    *) exit 2 ;;
  esac
done
[ "$boot_b_only" -eq 1 ] || exit 2
RESTORE_DTBO_IMAGE=""
RESTORE_DTBO_SHA256=""
[ -z "$ambient_dtbo$ambient_dtbo_sha" ] || printf 'ambient-dtbo-neutralized\n' >> "$MOCK_STATE_DIR/dtbo-neutralized.log"
process_starttime() {
  local stat_line=""
  local remainder=""
  local -a fields=()
  stat_line="$(< "/proc/$$/stat")"
  remainder="${stat_line##*) }"
  read -r -a fields <<< "$remainder"
  printf '%s\n' "${fields[19]}"
}
starttime="$(process_starttime)"
watcher_script="$(readlink -f "$0")"
count=0
[ ! -f "$MOCK_STATE_DIR/watcher.count" ] || count="$(cat "$MOCK_STATE_DIR/watcher.count")"
count=$((count + 1))
printf '%s\n' "$count" > "$MOCK_STATE_DIR/watcher.count"
printf '%s\n' "$$" >> "$MOCK_STATE_DIR/watcher.pids"
printf '%s\n' "$$" > "$MOCK_STATE_DIR/current-watcher.pid"
tmp="$ready.$$.tmp"
if [ -n "$nonce" ]; then
  {
    printf 'contract_version=2\n'
    printf 'pid=%s\n' "$$"
    printf 'starttime=%s\n' "$starttime"
    printf 'serial=%s\n' "$serial"
    printf 'restore_image=%s\n' "$restore"
    printf 'restore_sha256=%s\n' "$restore_sha"
    printf 'boot_b_only=1\n'
    printf 'restore_dtbo_image=none\n'
    printf 'restore_dtbo_sha256=none\n'
    printf 'nonce=%s\n' "$nonce"
    printf 'watcher_script=%s\n' "$watcher_script"
    printf 'challenge_file=%s\n' "$challenge_file"
    printf 'ack_file=%s\n' "$ack_file"
  } > "$tmp"
else
  {
    printf 'pid=%s\n' "$$"
    printf 'serial=%s\n' "$serial"
    printf 'restore_image=%s\n' "$restore"
    printf 'restore_sha256=%s\n' "$restore_sha"
  } > "$tmp"
fi
mv "$tmp" "$ready"
cleanup_mock_watcher() {
  rm -f "$ready" "$challenge_file" "$ack_file"
}
publish_mock_ack() {
  local actual=""
  local expected_prefix=""
  local challenge=""
  local ack_tmp=""
  local ack_count=0
  local mode=""

  [ -n "$nonce" ] || return 0
  [ -r "$challenge_file" ] || return 0
  actual="$(< "$challenge_file")"
  expected_prefix="contract_version=2"$'\n'"nonce=$nonce"$'\n'
  case "$actual" in
    "$expected_prefix"challenge=*) ;;
    *) return 0 ;;
  esac
  challenge="${actual##*$'\n'challenge=}"
  [[ "$challenge" =~ ^[0-9a-f]{64}$ ]] || return 0
  mode="$(cat "$MOCK_STATE_DIR/watcher-mode")"
  if [ "$mode" = "ignore-ack-1" ] && [ "$count" -eq 1 ]; then
    return 0
  fi
  [ ! -f "$MOCK_STATE_DIR/contract-ack.count" ] ||
    ack_count="$(cat "$MOCK_STATE_DIR/contract-ack.count")"
  ack_count=$((ack_count + 1))
  printf '%s\n' "$ack_count" > "$MOCK_STATE_DIR/contract-ack.count"
  ack_tmp="$ack_file.$$.tmp"
  {
    printf 'contract_version=2\n'
    printf 'pid=%s\n' "$$"
    printf 'starttime=%s\n' "$starttime"
    printf 'nonce=%s\n' "$nonce"
    printf 'challenge=%s\n' "$challenge"
  } > "$ack_tmp"
  mv "$ack_tmp" "$ack_file"

  case "$mode" in
    die-after-ack-*)
      if [ "$ack_count" -eq "${mode##*-}" ]; then
        (sleep 0.03; kill -KILL "$$" 2>/dev/null || true) &
      fi
      ;;
  esac
}
trap cleanup_mock_watcher EXIT
trap 'exit 0' INT TERM
trap 'publish_mock_ack || true' USR1
if [ "$(cat "$MOCK_STATE_DIR/watcher-mode")" = "die-first" ] && [ "$count" -eq 1 ]; then
  sleep 0.3
  exit 3
fi
while :; do sleep 0.1; done
MOCK

cat > "$MOCK_BIN/mock-writer" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
image=""
expected_sha=""
expected_boot_id=""
expected_kernel=""
required_watcher=""
require_watcher_contract=0
required_starttime=""
required_ready=""
required_nonce=""
required_script=""
required_restore=""
required_restore_sha=""
required_challenge=""
required_ack=""
required_watcher2=""
required_starttime2=""
required_ready2=""
required_nonce2=""
required_script2=""
required_restore2=""
required_restore_sha2=""
required_challenge2=""
required_ack2=""
lock_fd=""
reboot=0
tokens=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) image="$2"; shift 2 ;;
    --image-sha256) expected_sha="$2"; shift 2 ;;
    --expected-source-boot-id) expected_boot_id="$2"; shift 2 ;;
    --expected-source-kernel) expected_kernel="$2"; shift 2 ;;
    --expected-source-cmdline-token) tokens+=("$2"); shift 2 ;;
    --required-watcher-pid) required_watcher="$2"; shift 2 ;;
    --require-watcher-contract) require_watcher_contract=1; shift ;;
    --required-watcher-starttime) required_starttime="$2"; shift 2 ;;
    --required-watcher-ready-file) required_ready="$2"; shift 2 ;;
    --required-watcher-nonce) required_nonce="$2"; shift 2 ;;
    --required-watcher-script) required_script="$2"; shift 2 ;;
    --required-watcher-restore-image) required_restore="$2"; shift 2 ;;
    --required-watcher-restore-sha256) required_restore_sha="$2"; shift 2 ;;
    --required-watcher-challenge-file) required_challenge="$2"; shift 2 ;;
    --required-watcher-ack-file) required_ack="$2"; shift 2 ;;
    --required-watcher2-pid) required_watcher2="$2"; shift 2 ;;
    --required-watcher2-starttime) required_starttime2="$2"; shift 2 ;;
    --required-watcher2-ready-file) required_ready2="$2"; shift 2 ;;
    --required-watcher2-nonce) required_nonce2="$2"; shift 2 ;;
    --required-watcher2-script) required_script2="$2"; shift 2 ;;
    --required-watcher2-restore-image) required_restore2="$2"; shift 2 ;;
    --required-watcher2-restore-sha256) required_restore_sha2="$2"; shift 2 ;;
    --required-watcher2-challenge-file) required_challenge2="$2"; shift 2 ;;
    --required-watcher2-ack-file) required_ack2="$2"; shift 2 ;;
    --phone-lock-fd) lock_fd="$2"; shift 2 ;;
    --reboot) reboot=1; shift ;;
    --serial|--host|--user|--password) shift 2 ;;
    *) exit 2 ;;
  esac
done
actual_sha="$(sha256sum "$image" | awk '{ print $1 }')"
[ "$actual_sha" = "$expected_sha" ] || exit 4
if [ "$require_watcher_contract" -eq 1 ]; then
  [ -n "$required_watcher" ]
  [ -n "$required_starttime" ]
  [ -n "$required_ready" ]
  [ -n "$required_nonce" ]
  [ -n "$required_script" ]
  [ -n "$required_restore" ]
  [ -n "$required_restore_sha" ]
  [ -n "$required_challenge" ]
  [ -n "$required_ack" ]
  [ -n "$required_watcher2" ]
  [ -n "$required_starttime2" ]
  [ -n "$required_ready2" ]
  [ -n "$required_nonce2" ]
  [ -n "$required_script2" ]
  [ -n "$required_restore2" ]
  [ -n "$required_restore_sha2" ]
  [ -n "$required_challenge2" ]
  [ -n "$required_ack2" ]
  kill -0 "$required_watcher"
  kill -0 "$required_watcher2"
  [ "$required_watcher" != "$required_watcher2" ]
  [ "$required_restore" = "$required_restore2" ]
  [ "$required_restore_sha" = "$required_restore_sha2" ]
  if [ "$(cat "$MOCK_STATE_DIR/watcher-mode")" = "die-at-writer-entry" ]; then
    kill -KILL "$required_watcher" 2>/dev/null || true
    for _ in {1..100}; do
      kill -0 "$required_watcher" 2>/dev/null || break
      sleep 0.01
    done
    printf 'mandatory-contract-rejected-dead\n' >&2
    exit 3
  fi
  printf 'required=1 pid=%s starttime=%s nonce=%s pid2=%s starttime2=%s nonce2=%s\n' \
    "$required_watcher" "$required_starttime" "$required_nonce" \
    "$required_watcher2" "$required_starttime2" "$required_nonce2" >> "$MOCK_STATE_DIR/writer-contract.log"
elif [ -n "$required_watcher" ]; then
  exit 8
fi
[ -n "$lock_fd" ] && [ -e "/proc/$$/fd/$lock_fd" ]
state="$(cat "$MOCK_STATE_DIR/state")"
case "$state" in
  source)
    boot_id="$SOURCE_BOOT_ID"
    kernel="$SOURCE_KERNEL"
    cmdline="$SOURCE_CMDLINE"
    ;;
  target)
    boot_id="$TARGET_BOOT_ID"
    kernel="$TARGET_KERNEL"
    cmdline="$TARGET_CMDLINE"
    ;;
  *) exit 7 ;;
esac
[ "$boot_id" = "$expected_boot_id" ] || exit 7
[ "$kernel" = "$expected_kernel" ] || exit 7
for token in "${tokens[@]}"; do
  case " $cmdline " in
    *" $token "*) ;;
    *) exit 7 ;;
  esac
done
kind="candidate"
if [ "$reboot" -eq 0 ] && [ "$image" = "$(cat "$MOCK_STATE_DIR/restore.path")" ]; then
  kind="restore"
fi
printf 'kind=%s boot_id=%s kernel=%s reboot=%s image_sha=%s\n' \
  "$kind" "$expected_boot_id" "$expected_kernel" "$reboot" "$expected_sha" >> "$MOCK_STATE_DIR/writer.log"
if [ "$kind" = "candidate" ] && [ "$(cat "$MOCK_STATE_DIR/watcher-mode")" = "kill-primary-after-candidate-write" ]; then
  kill -KILL "$required_watcher" 2>/dev/null || true
  for _ in {1..100}; do
    kill -0 "$required_watcher" 2>/dev/null || break
    sleep 0.01
  done
fi
if [ "$kind" = "restore" ]; then
  printf 'source\n' > "$MOCK_STATE_DIR/state"
  exit 0
fi
case "$(cat "$MOCK_STATE_DIR/writer-behavior")" in
  success-target) printf 'target\n' > "$MOCK_STATE_DIR/state" ;;
  success-recovery) printf 'recovery\n' > "$MOCK_STATE_DIR/state" ;;
  success-no-usb) printf 'no-usb\n' > "$MOCK_STATE_DIR/state" ;;
  stay-source) ;;
  mutate-restore-stay-source) printf 'mutation\n' >> "$(cat "$MOCK_STATE_DIR/restore.path")" ;;
  fail-no-source) printf 'no-usb\n' > "$MOCK_STATE_DIR/state"; exit 4 ;;
  stale-source) printf 'source\n' > "$MOCK_STATE_DIR/state"; exit 7 ;;
  sleep)
    : > "$MOCK_STATE_DIR/writer-entered"
    trap 'exit 130' INT TERM
    sleep 30
    ;;
  *) exit 2 ;;
esac
MOCK

chmod 755 "$MOCK_BIN"/*

new_case() {
  local name="$1"
  local case_dir="$TMP/case-$name"

  mkdir -p "$case_dir/logs"
  printf 'source\n' > "$case_dir/state"
  printf 'normal\n' > "$case_dir/watcher-mode"
  printf 'success-target\n' > "$case_dir/writer-behavior"
  printf 'ok\n' > "$case_dir/fastboot-behavior"
  : > "$case_dir/fastboot.log"
  : > "$case_dir/fastboot-writes.log"
  : > "$case_dir/phone-access.log"
  : > "$case_dir/writer.log"
  : > "$case_dir/writer-contract.log"
  : > "$case_dir/remote-writer-invocations"
  printf 'test-image-%s\n' "$name" > "$case_dir/test.img"
  printf 'restore-image-%s\n' "$name" > "$case_dir/restore.img"
  printf '%s\n' "$case_dir/restore.img" > "$case_dir/restore.path"
  printf '%s\n' "$case_dir"
}

helper_env() {
  local case_dir="$1"
  shift
  local -a env_args=(
    PATH="$MOCK_BIN:/usr/bin:/bin" \
    HOTDOG_ROOT="$ROOT" \
    HOTDOG_LOCAL_ENV="$case_dir/no-local-env" \
    HOTDOG_LOG_ROOT="$case_dir/logs" \
    HOTDOG_TARGET_SERIAL="$SERIAL" \
    ANDROID_SERIAL="$SERIAL" \
    HOTDOG_PMOS_HOST="172.16.42.1" \
    HOTDOG_PMOS_USER="user" \
    HOTDOG_PMOS_PASSWORD="password" \
    HOTDOG_FLASH_BOOT_B_SSH_HELPER="$MOCK_BIN/mock-writer" \
    HOTDOG_RESCUE_WATCHER_HELPER="$MOCK_BIN/mock-watcher" \
    HOTDOG_FORCE_RESCUE_FALLBACK=1 \
    MOCK_STATE_DIR="$case_dir" \
    SERIAL="$SERIAL" \
    SOURCE_BOOT_ID="$SOURCE_BOOT_ID" \
    SOURCE_KERNEL="$SOURCE_KERNEL" \
    SOURCE_CMDLINE="$SOURCE_CMDLINE" \
    TARGET_BOOT_ID="$TARGET_BOOT_ID" \
    TARGET_KERNEL="$TARGET_KERNEL" \
    TARGET_CMDLINE="$TARGET_CMDLINE"
  )

  if [ "${HELPER_ENV_SETSID:-0}" -eq 1 ]; then
    exec setsid env "${env_args[@]}" "$@"
  fi
  env "${env_args[@]}" "$@"
}

MOCK_CONTRACT_PID=""
MOCK_CONTRACT_STARTTIME=""
MOCK_CONTRACT_READY=""
MOCK_CONTRACT_NONCE=""
MOCK_CONTRACT_SCRIPT=""
MOCK_CONTRACT_CHALLENGE=""
MOCK_CONTRACT_ACK=""
MOCK_CONTRACT_LAUNCHER_PID=""
MOCK_CONTRACT2_PID=""
MOCK_CONTRACT2_STARTTIME=""
MOCK_CONTRACT2_READY=""
MOCK_CONTRACT2_NONCE=""
MOCK_CONTRACT2_SCRIPT=""
MOCK_CONTRACT2_CHALLENGE=""
MOCK_CONTRACT2_ACK=""
MOCK_CONTRACT_ARGS=()

proc_starttime() {
  local pid="$1"
  local stat_line=""
  local remainder=""
  local -a fields=()

  stat_line="$(< "/proc/$pid/stat")"
  remainder="${stat_line##*) }"
  read -r -a fields <<< "$remainder"
  printf '%s\n' "${fields[19]}"
}

start_mock_contract_watcher() {
  local case_dir="$1"
  local restore="$2"
  local restore_sha="$3"
  local mode="${4:-normal}"
  local watcher_script="${5:-$MOCK_BIN/mock-watcher}"

  MOCK_CONTRACT_READY="$case_dir/manual-watcher-1.ready"
  MOCK_CONTRACT_CHALLENGE="$case_dir/manual-watcher-1.challenge"
  MOCK_CONTRACT_ACK="$case_dir/manual-watcher-1.ack"
  MOCK_CONTRACT_NONCE="$(printf '%s' "$case_dir-contract-1" | sha256sum | awk '{ print $1 }')"
  MOCK_CONTRACT_SCRIPT="$(readlink -f "$watcher_script")"
  MOCK_CONTRACT2_READY="$case_dir/manual-watcher-2.ready"
  MOCK_CONTRACT2_CHALLENGE="$case_dir/manual-watcher-2.challenge"
  MOCK_CONTRACT2_ACK="$case_dir/manual-watcher-2.ack"
  MOCK_CONTRACT2_NONCE="$(printf '%s' "$case_dir-contract-2" | sha256sum | awk '{ print $1 }')"
  MOCK_CONTRACT2_SCRIPT="$MOCK_CONTRACT_SCRIPT"
  printf '%s\n' "$mode" > "$case_dir/watcher-mode"
  rm -f "$MOCK_CONTRACT_READY" "$MOCK_CONTRACT_CHALLENGE" "$MOCK_CONTRACT_ACK" \
    "$MOCK_CONTRACT2_READY" "$MOCK_CONTRACT2_CHALLENGE" "$MOCK_CONTRACT2_ACK"

  helper_env "$case_dir" HOTDOG_RESCUE_LOG_TEE=0 "$watcher_script" \
    --serial "$SERIAL" \
    --restore-boot-b "$restore" \
    --restore-boot-b-sha256 "$restore_sha" \
    --boot-b-only \
    --after-restore none \
    --timeout 30 \
    --poll 1 \
    --ready-file "$MOCK_CONTRACT_READY" \
    --contract-nonce "$MOCK_CONTRACT_NONCE" \
    --contract-challenge-file "$MOCK_CONTRACT_CHALLENGE" \
    --contract-ack-file "$MOCK_CONTRACT_ACK" \
    > "$case_dir/manual-watcher.log" 2>&1 &
  MOCK_CONTRACT_LAUNCHER_PID=$!

  helper_env "$case_dir" HOTDOG_RESCUE_LOG_TEE=0 "$watcher_script" \
    --serial "$SERIAL" \
    --restore-boot-b "$restore" \
    --restore-boot-b-sha256 "$restore_sha" \
    --boot-b-only \
    --after-restore none \
    --timeout 30 \
    --poll 1 \
    --ready-file "$MOCK_CONTRACT2_READY" \
    --contract-nonce "$MOCK_CONTRACT2_NONCE" \
    --contract-challenge-file "$MOCK_CONTRACT2_CHALLENGE" \
    --contract-ack-file "$MOCK_CONTRACT2_ACK" \
    > "$case_dir/manual-watcher-2.log" 2>&1 &
  for _ in {1..100}; do
    [ -s "$MOCK_CONTRACT_READY" ] && [ -s "$MOCK_CONTRACT2_READY" ] && break
    sleep 0.05
  done
  [ -s "$MOCK_CONTRACT_READY" ] || fail "manual contract watcher 1 did not publish readiness"
  [ -s "$MOCK_CONTRACT2_READY" ] || fail "manual contract watcher 2 did not publish readiness"
  MOCK_CONTRACT_PID="$(sed -n '2s/^pid=//p' "$MOCK_CONTRACT_READY")"
  MOCK_CONTRACT_STARTTIME="$(sed -n '3s/^starttime=//p' "$MOCK_CONTRACT_READY")"
  MOCK_CONTRACT2_PID="$(sed -n '2s/^pid=//p' "$MOCK_CONTRACT2_READY")"
  MOCK_CONTRACT2_STARTTIME="$(sed -n '3s/^starttime=//p' "$MOCK_CONTRACT2_READY")"
  kill -0 "$MOCK_CONTRACT_PID" 2>/dev/null || fail "manual contract watcher is not alive"
  kill -0 "$MOCK_CONTRACT2_PID" 2>/dev/null || fail "manual contract watcher 2 is not alive"
  grep -Fxq "$MOCK_CONTRACT_PID" "$case_dir/watcher.pids" 2>/dev/null ||
    printf '%s\n' "$MOCK_CONTRACT_PID" >> "$case_dir/watcher.pids"
  grep -Fxq "$MOCK_CONTRACT2_PID" "$case_dir/watcher.pids" 2>/dev/null ||
    printf '%s\n' "$MOCK_CONTRACT2_PID" >> "$case_dir/watcher.pids"
  MOCK_CONTRACT_ARGS=(
    --require-watcher-contract
    --required-watcher-pid "$MOCK_CONTRACT_PID"
    --required-watcher-starttime "$MOCK_CONTRACT_STARTTIME"
    --required-watcher-ready-file "$MOCK_CONTRACT_READY"
    --required-watcher-nonce "$MOCK_CONTRACT_NONCE"
    --required-watcher-script "$MOCK_CONTRACT_SCRIPT"
    --required-watcher-restore-image "$restore"
    --required-watcher-restore-sha256 "$restore_sha"
    --required-watcher-challenge-file "$MOCK_CONTRACT_CHALLENGE"
    --required-watcher-ack-file "$MOCK_CONTRACT_ACK"
    --required-watcher2-pid "$MOCK_CONTRACT2_PID"
    --required-watcher2-starttime "$MOCK_CONTRACT2_STARTTIME"
    --required-watcher2-ready-file "$MOCK_CONTRACT2_READY"
    --required-watcher2-nonce "$MOCK_CONTRACT2_NONCE"
    --required-watcher2-script "$MOCK_CONTRACT2_SCRIPT"
    --required-watcher2-restore-image "$restore"
    --required-watcher2-restore-sha256 "$restore_sha"
    --required-watcher2-challenge-file "$MOCK_CONTRACT2_CHALLENGE"
    --required-watcher2-ack-file "$MOCK_CONTRACT2_ACK"
  )
}

write_forged_contract_ready() {
  local file="$1"
  local pid="$2"
  local starttime="$3"
  local script="$4"
  local restore="$5"
  local restore_sha="$6"
  local nonce="$7"
  local challenge_file="$8"
  local ack_file="$9"

  {
    printf 'contract_version=2\n'
    printf 'pid=%s\n' "$pid"
    printf 'starttime=%s\n' "$starttime"
    printf 'serial=%s\n' "$SERIAL"
    printf 'restore_image=%s\n' "$restore"
    printf 'restore_sha256=%s\n' "$restore_sha"
    printf 'boot_b_only=1\n'
    printf 'restore_dtbo_image=none\n'
    printf 'restore_dtbo_sha256=none\n'
    printf 'nonce=%s\n' "$nonce"
    printf 'watcher_script=%s\n' "$script"
    printf 'challenge_file=%s\n' "$challenge_file"
    printf 'ack_file=%s\n' "$ack_file"
  } > "$file"
}

run_ssh_case() {
  local case_dir="$1"
  local output="$2"
  local image_sha=""
  local restore_sha=""
  shift 2
  local -a env_overrides=("$@")

  image_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  helper_env "$case_dir" "${env_overrides[@]}" "$ROOT/scripts/test-boot-b-image.sh" \
    --image "$case_dir/test.img" \
    --image-sha256 "$image_sha" \
    --restore-boot-b "$case_dir/restore.img" \
    --restore-boot-b-sha256 "$restore_sha" \
    --serial "$SERIAL" \
    --from-pmos-ssh \
    --start-rescue-watcher \
    --require-dirty-survival \
    --expect-source-kernel-prefix 4.14.357-openela-perf \
    --expect-source-cmdline-token androidboot.slot_suffix=_b \
    --expect-source-cmdline-token "androidboot.serialno=$SERIAL" \
    --expect-kernel-prefix 6.17.0-sm8150 \
    --expect-cmdline-token rdinit=/hotdog-mainline-wrapper \
    --expect-cmdline-token androidboot.slot_suffix=_b \
    --expect-cmdline-token "androidboot.serialno=$SERIAL" \
    --restore-after system \
    --boot-wait 3 \
    --poll 1 \
    --fastboot-timeout 2 \
    --rescue-watch-timeout 30 \
    --rescue-watch-poll 1 \
    > "$output" 2>&1
}

assert_live_current_watcher() {
  local case_dir="$1"
  local live=0
  local pid=""

  case_watcher_pids "$case_dir" > "$case_dir/all-watcher-pids"
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null && live=$((live + 1))
  done < "$case_dir/all-watcher-pids"
  [ "$live" -ge 2 ] || fail "expected an attested rescue pair, found $live live watcher(s)"
}

assert_no_live_case_watchers() {
  local case_dir="$1"
  local pid=""

  case_watcher_pids "$case_dir" > "$case_dir/all-watcher-pids"
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    ! kill -0 "$pid" 2>/dev/null || fail "unexpected live watcher PID $pid"
  done < "$case_dir/all-watcher-pids"
}

test_strict_success_contract() {
  local case_dir=""

  case_dir="$(new_case strict-success)"
  printf 'success-target\n' > "$case_dir/writer-behavior"
  run_ssh_case "$case_dir" "$case_dir/output.log" || fail "strict target success returned nonzero"
  grep -q '^kind=candidate ' "$case_dir/writer.log" || fail "strict success did not invoke candidate writer"
  ! grep -q '^kind=restore ' "$case_dir/writer.log" || fail "strict success unexpectedly restored boot_b"
  [ -e "$case_dir/atomic-ack-session" ] || fail "strict success did not bind identity and ACK in one SSH session"
  [ ! -e "$case_dir/legacy-ack-session" ] || fail "strict success used the legacy second ACK session"
  sleep 0.2
  assert_no_live_case_watchers "$case_dir"
  pass "strict success keeps D1 intentionally and stops watcher only after ACK"
}

test_atomic_ack_peer_flip_refused() {
  local case_dir=""
  local status=0

  case_dir="$(new_case atomic-peer-flip)"
  printf 'success-target\n' > "$case_dir/writer-behavior"
  set +e
  run_ssh_case "$case_dir" "$case_dir/output.log" MOCK_ATOMIC_PEER_FLIP=1
  status=$?
  set -e

  [ "$status" -eq 5 ] || fail "atomic ACK peer flip returned $status instead of 5"
  [ -e "$case_dir/atomic-peer-flipped" ] || fail "atomic peer-flip injection was not exercised"
  [ ! -e "$case_dir/atomic-ack-session" ] || fail "peer flip produced an atomic ACK proof"
  [ ! -e "$case_dir/legacy-ack-session" ] || fail "peer flip fell back to a second ACK session"
  grep -q 'lacked its atomic watchdog ACK proof' "$case_dir/output.log" ||
    fail "missing atomic ACK proof was not diagnosed"
  grep -q '^kind=restore ' "$case_dir/writer.log" || fail "peer flip did not trigger strict source rollback"
  pass "strict success rejects a peer change inside the identity-and-ACK transaction"
}

test_legacy_generic_no_rescue_contract() {
  local case_dir=""
  local image_sha=""
  local restore_sha=""

  case_dir="$(new_case legacy-generic)"
  printf 'success-target\n' > "$case_dir/writer-behavior"
  image_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  if ! helper_env "$case_dir" "$ROOT/scripts/test-boot-b-image.sh" \
    --image "$case_dir/test.img" \
    --image-sha256 "$image_sha" \
    --restore-boot-b "$case_dir/restore.img" \
    --restore-boot-b-sha256 "$restore_sha" \
    --serial "$SERIAL" \
    --from-pmos-ssh \
    --restore-after system \
    --boot-wait 3 \
    --poll 1 \
    > "$case_dir/output.log" 2>&1; then
    fail "legacy generic no-rescue success returned nonzero"
  fi
  grep -q 'Legacy generic result contract' "$case_dir/output.log" ||
    fail "legacy generic success did not document its dirty boot_b contract"
  [ ! -e "$case_dir/current-watcher.pid" ] || fail "legacy no-rescue case unexpectedly started a watcher"
  pass "legacy generic no-rescue success retains its historical zero status"
}

test_lineage_bridge_strict_contract() {
  local case_dir=""
  local r5_image="$ROOT/images/pmos-experiments/2026-07-11-130500-lineage414-r5-kexec-fbwait-nopaint-acm-rootwatchdog/boot-noefi-pmosdtb-watchdog-300s.img"
  local r5_sha="23fa53d382425e9414a2e2a4b6e10f42d59ce1d6623b7fa1fbebf21ffe0c8a50"
  local override=""
  local override_index=0
  local status=0
  local -a override_args=()

  [ "$(sha256sum "$r5_image" | awk '{ print $1 }')" = "$r5_sha" ] ||
    fail "pinned R5 test artifact hash is unavailable"
  case_dir="$(new_case lineage-bridge-fresh)"
  printf '%s\n' "$r5_image" > "$case_dir/restore.path"
  printf 'success-target\n' > "$case_dir/writer-behavior"
  set +e
  helper_env "$case_dir" \
    HOTDOG_FROM_PMOS_SSH=1 \
    HOTDOG_STABLE_PMOS_BOOT_B="$r5_image" \
    MOCK_REBOOT_TARGET_STATE=target \
    TARGET_KERNEL="$SOURCE_KERNEL" \
    TARGET_CMDLINE="$SOURCE_CMDLINE" \
    "$ROOT/scripts/test-lineage414-r5-kexec-bridge.sh" \
    > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "fresh lineage R5 bridge returned $status instead of 0"
  grep -q 'atomically acknowledged in the strict SSH identity session' "$case_dir/output.log" ||
    fail "fresh lineage R5 bridge did not atomically ACK its strict identity"
  [ -s "$case_dir/remote-writer-invocations" ] || fail "R5 canonical SSH helper did not reach its writer"
  [ ! -s "$case_dir/writer.log" ] || fail "R5 accepted the ambient substitute SSH helper"
  [ ! -e "$case_dir/watcher.count" ] || fail "R5 accepted the ambient substitute rescue helper"
  [ -e "$case_dir/atomic-ack-session" ] || fail "R5 strict identity and ACK were not one session"
  [ ! -e "$case_dir/legacy-ack-session" ] || fail "R5 used a second legacy ACK session"
  grep -q "Expected test image SHA256: $r5_sha" "$case_dir/output.log" || fail "R5 image hash was not pinned"
  grep -q "Restore image SHA256: $r5_sha" "$case_dir/output.log" ||
    fail "R5 caller arguments weakened the pinned restore hash"
  assert_no_live_case_watchers "$case_dir"

  for override in \
    '--restore-after none' \
    '--boot-wait 1' \
    '--poll 99' \
    '--fastboot-timeout 1' \
    '--rescue-watch-timeout 1' \
    '--rescue-watch-poll 99' \
    '--no-set-active-b' \
    '--expected-product wrong' \
    '--from-pmos-ssh'
  do
    override_index=$((override_index + 1))
    case_dir="$(new_case "lineage-bridge-override-$override_index")"
    read -r -a override_args <<< "$override"
    set +e
    helper_env "$case_dir" \
      HOTDOG_STABLE_PMOS_BOOT_B="$r5_image" \
      "$ROOT/scripts/test-lineage414-r5-kexec-bridge.sh" \
      "${override_args[@]}" > "$case_dir/output.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail "R5 override '$override' returned $status instead of 2"
    [ ! -s "$case_dir/writer.log" ] || fail "R5 override '$override' reached the writer"
  done

  case_dir="$(new_case lineage-bridge-bad-source-mode)"
  set +e
  helper_env "$case_dir" HOTDOG_FROM_PMOS_SSH=unattested \
    HOTDOG_STABLE_PMOS_BOOT_B="$r5_image" \
    "$ROOT/scripts/test-lineage414-r5-kexec-bridge.sh" > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "R5 accepted an unattested source mode with status $status"

  case_dir="$(new_case lineage-bridge-stale)"
  printf '%s\n' "$r5_image" > "$case_dir/restore.path"
  printf 'stay-source\n' > "$case_dir/writer-behavior"
  set +e
  helper_env "$case_dir" \
    HOTDOG_FROM_PMOS_SSH=1 \
    HOTDOG_STABLE_PMOS_BOOT_B="$r5_image" \
    MOCK_REBOOT_TARGET_STATE=source \
    TARGET_KERNEL="$SOURCE_KERNEL" \
    TARGET_CMDLINE="$SOURCE_CMDLINE" \
    "$ROOT/scripts/test-lineage414-r5-kexec-bridge.sh" \
    > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 5 ] || fail "stale lineage R5 bridge returned $status instead of 5"
  grep -q 'Strict source-SSH rollback readback verified' "$case_dir/output.log" ||
    fail "stale lineage R5 bridge did not complete strict rollback"

  case_dir="$(new_case lineage-bridge-wrong)"
  printf '%s\n' "$r5_image" > "$case_dir/restore.path"
  printf 'success-target\n' > "$case_dir/writer-behavior"
  set +e
  helper_env "$case_dir" \
    HOTDOG_FROM_PMOS_SSH=1 \
    HOTDOG_STABLE_PMOS_BOOT_B="$r5_image" \
    MOCK_REBOOT_TARGET_STATE=target \
    "$ROOT/scripts/test-lineage414-r5-kexec-bridge.sh" \
    > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 5 ] || fail "wrong-identity lineage R5 bridge returned $status instead of 5"
  grep -q "expected kernel prefix '4.14.357-openela-perf'" "$case_dir/output.log" ||
    fail "wrong lineage R5 target identity was not diagnosed"
  assert_live_current_watcher "$case_dir"
  pass "lineage R5 pins canonical helpers and is 0 only when fresh, identified and atomically ACKed"
}

test_watcher_dies_after_remote_readback() {
  local case_dir=""
  local expected_sha=""
  local restore_sha=""
  local status=0

  case_dir="$(new_case watcher-post-readback)"
  expected_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  start_mock_contract_watcher "$case_dir" "$case_dir/restore.img" "$restore_sha" normal \
    "$ROOT/scripts/rescue-boot-b-when-visible.sh"

  set +e
  helper_env "$case_dir" \
    KILL_WATCHER_DURING_REMOTE_WRITE_PID="$MOCK_CONTRACT_PID" \
    "$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
    --image "$case_dir/test.img" \
    --image-sha256 "$expected_sha" \
    --serial "$SERIAL" \
    --host 172.16.42.1 \
    --user user \
    --password password \
    "${MOCK_CONTRACT_ARGS[@]}" \
    --reboot \
    > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  wait "$MOCK_CONTRACT_LAUNCHER_PID" 2>/dev/null || true

  [ "$status" -eq 3 ] || fail "post-readback watcher death returned $status instead of 3"
  [ -e "$case_dir/remote-writer-entered" ] || fail "mock remote writer transport was not reached"
  grep -q 'Rescue quorum lost during remote boot_b writer/readback' "$case_dir/output.log" ||
    fail "writer-transport watcher death was not diagnosed"
  kill -0 "$MOCK_CONTRACT2_PID" 2>/dev/null || fail "independent rescue watcher died with primary"
  [ ! -e "$case_dir/reboot-called" ] || fail "reboot was called after post-readback watcher death"
  ! grep -q 'Cleaning remote work directory' "$case_dir/output.log" ||
    fail "post-readback liveness was not checked immediately after the writer"
  pass "watcher death during remote writer transport aborts SSH while backup rescue remains"
}

run_actual_helper_transport_case() {
  local case_dir="$1"
  local kill_variable="$2"
  local expected_sha=""
  local restore_sha=""

  expected_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  start_mock_contract_watcher "$case_dir" "$case_dir/restore.img" "$restore_sha"
  helper_env "$case_dir" "$kill_variable=$MOCK_CONTRACT_PID" \
    "$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
    --image "$case_dir/test.img" \
    --image-sha256 "$expected_sha" \
    --serial "$SERIAL" \
    --host 172.16.42.1 \
    --user user \
    --password password \
    "${MOCK_CONTRACT_ARGS[@]}" \
    --reboot
}

test_ssh_ack_transport_windows() {
  local case_dir=""
  local status=0

  case_dir="$(new_case ssh-before-writer)"
  set +e
  run_actual_helper_transport_case "$case_dir" \
    KILL_WATCHER_BEFORE_REMOTE_WRITE_PID \
    > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "SSH pre-writer watcher death returned $status instead of 3"
  [ ! -s "$case_dir/remote-writer-invocations" ] || fail "SSH writer dispatched after pre-transport watcher death"
  [ ! -e "$case_dir/reboot-called" ] || fail "SSH reboot followed pre-writer watcher death"
  kill -0 "$MOCK_CONTRACT2_PID" 2>/dev/null || fail "backup watcher missing after pre-writer death"
  kill_case_watchers "$case_dir"

  case_dir="$(new_case ssh-before-reboot)"
  set +e
  run_actual_helper_transport_case "$case_dir" \
    KILL_WATCHER_BEFORE_REBOOT_PID \
    > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "SSH pre-reboot watcher death returned $status instead of 3"
  [ -s "$case_dir/remote-writer-invocations" ] || fail "SSH pre-reboot case never completed writer transport"
  [ -e "$case_dir/reboot-transport-entered" ] || fail "SSH pre-reboot transport was not entered"
  [ ! -e "$case_dir/reboot-called" ] || fail "SSH reboot dispatched after pre-transport watcher death"
  kill -0 "$MOCK_CONTRACT2_PID" 2>/dev/null || fail "backup watcher missing after pre-reboot death"
  kill_case_watchers "$case_dir"

  case_dir="$(new_case ssh-during-reboot)"
  set +e
  run_actual_helper_transport_case "$case_dir" \
    KILL_WATCHER_DURING_REBOOT_PID \
    > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "SSH in-flight reboot watcher death returned $status instead of 3"
  [ -e "$case_dir/reboot-transport-entered" ] || fail "SSH in-flight reboot transport was not entered"
  [ ! -e "$case_dir/reboot-called" ] || fail "SSH reboot dispatched after in-flight watcher death"
  kill -0 "$MOCK_CONTRACT2_PID" 2>/dev/null || fail "backup watcher missing during SSH reboot abort"
  kill_case_watchers "$case_dir"
  pass "SSH ACK-to-transport deaths abort writer/reboot while an independent rescue remains"
}

test_ssh_reboot_dispatch_proof() {
  local case_dir=""
  local expected_sha=""
  local restore_sha=""
  local status=0

  case_dir="$(new_case ssh-reboot-proof-ok)"
  expected_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  start_mock_contract_watcher "$case_dir" "$case_dir/restore.img" "$restore_sha"
  helper_env "$case_dir" "$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
    --image "$case_dir/test.img" --image-sha256 "$expected_sha" \
    --serial "$SERIAL" --host 172.16.42.1 --user user --password password \
    "${MOCK_CONTRACT_ARGS[@]}" --reboot > "$case_dir/output.log" 2>&1 ||
    fail "proven SSH reboot dispatch returned nonzero"
  grep -q 'Reboot SSH transport status: 255' "$case_dir/output.log" || fail "SSH status 255 was not classified"
  grep -q 'Reboot dispatch proof verified' "$case_dir/output.log" || fail "SSH reboot proof was not verified"
  [ -e "$case_dir/reboot-called" ] || fail "proven SSH reboot was not dispatched"
  kill_case_watchers "$case_dir"

  case_dir="$(new_case ssh-reboot-proof-missing)"
  expected_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  start_mock_contract_watcher "$case_dir" "$case_dir/restore.img" "$restore_sha"
  set +e
  helper_env "$case_dir" MOCK_REBOOT_NO_DISPATCH_PROOF=1 \
    "$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
    --image "$case_dir/test.img" --image-sha256 "$expected_sha" \
    --serial "$SERIAL" --host 172.16.42.1 --user user --password password \
    "${MOCK_CONTRACT_ARGS[@]}" --reboot > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "ping drop without SSH dispatch proof was accepted"
  grep -q 'reboot dispatch proof is missing' "$case_dir/output.log" || fail "missing SSH proof was not diagnosed"
  kill_case_watchers "$case_dir"

  case_dir="$(new_case ssh-reboot-status-bad)"
  expected_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  start_mock_contract_watcher "$case_dir" "$case_dir/restore.img" "$restore_sha"
  set +e
  helper_env "$case_dir" MOCK_REBOOT_SSH_STATUS=42 \
    "$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
    --image "$case_dir/test.img" --image-sha256 "$expected_sha" \
    --serial "$SERIAL" --host 172.16.42.1 --user user --password password \
    "${MOCK_CONTRACT_ARGS[@]}" --reboot > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "unexpected SSH status 42 was accepted"
  grep -q 'reboot SSH transport failed with status 42' "$case_dir/output.log" || fail "bad SSH status was not diagnosed"
  kill_case_watchers "$case_dir"
  pass "SSH reboot requires an accepted status, nonce dispatch proof and ping drop"
}

run_direct_fastboot_transport_case() {
  local case_dir="$1"
  local stage="$2"
  local image_sha=""
  local restore_sha=""

  printf 'fastboot\n' > "$case_dir/state"
  image_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  helper_env "$case_dir" MOCK_FASTBOOT_KILL_WATCHER_STAGE="$stage" \
    "$ROOT/scripts/test-boot-b-image.sh" \
    --image "$case_dir/test.img" \
    --image-sha256 "$image_sha" \
    --restore-boot-b "$case_dir/restore.img" \
    --restore-boot-b-sha256 "$restore_sha" \
    --serial "$SERIAL" \
    --expected-product "msmnile hotdog" \
    --start-rescue-watcher \
    --require-dirty-survival \
    --restore-after system \
    --boot-wait 3 \
    --poll 1 \
    --fastboot-timeout 2 \
    --rescue-watch-timeout 30 \
    --rescue-watch-poll 1
}

test_fastboot_ack_transport_windows() {
  local stage=""
  local case_dir=""
  local status=0

  for stage in before during; do
    case_dir="$(new_case "fastboot-reboot-$stage")"
    set +e
    run_direct_fastboot_transport_case "$case_dir" "$stage" > "$case_dir/output.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 3 ] || fail "fastboot $stage-transport watcher death returned $status instead of 3"
    grep -q '^FLASH boot_b$' "$case_dir/fastboot-writes.log" || fail "fastboot $stage case never wrote candidate boot_b"
    [ -e "$case_dir/fastboot-reboot-transport-entered" ] || fail "fastboot $stage reboot transport was not entered"
    [ ! -e "$case_dir/fastboot-reboot-dispatched" ] || fail "fastboot reboot dispatched after $stage-transport watcher death"
    assert_live_current_watcher "$case_dir"
  done
  pass "fastboot ACK-to-transport deaths abort reboot while the redundant rescue is rearmed"
}

run_restore_fastboot_transport_case() {
  local case_dir="$1"
  local stage="$2"
  local image_sha=""
  local restore_sha=""

  printf 'fastboot\n' > "$case_dir/state"
  image_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  helper_env "$case_dir" MOCK_FASTBOOT_KILL_ON="$stage" MOCK_REBOOT_STATE=fastboot \
    "$ROOT/scripts/test-boot-b-image.sh" \
    --image "$case_dir/test.img" \
    --image-sha256 "$image_sha" \
    --restore-boot-b "$case_dir/restore.img" \
    --restore-boot-b-sha256 "$restore_sha" \
    --serial "$SERIAL" \
    --expected-product "msmnile hotdog" \
    --start-rescue-watcher \
    --require-dirty-survival \
    --restore-after system \
    --boot-wait 3 \
    --poll 1 \
    --fastboot-timeout 2 \
    --rescue-watch-timeout 30 \
    --rescue-watch-poll 1
}

test_restore_fastboot_transport_windows() {
  local stage=""
  local marker=""
  local case_dir=""
  local status=0

  for stage in restore-flash restore-set-active restore-reboot; do
    case_dir="$(new_case "fastboot-$stage-death")"
    set +e
    run_restore_fastboot_transport_case "$case_dir" "$stage" > "$case_dir/output.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 3 ] || fail "$stage watcher death returned $status instead of 3"
    marker="${stage#restore-}"
    [ -e "$case_dir/fastboot-restore-$marker-entered" ] || fail "$stage transport was not entered"
    [ ! -e "$case_dir/fastboot-restore-$marker-dispatched" ] ||
      fail "$stage dispatched after rescue quorum death"
    grep -q 'rescue pair degraded during' "$case_dir/output.log" ||
      fail "$stage quorum loss was not diagnosed"
    assert_live_current_watcher "$case_dir"
  done
  pass "restore flash, slot activation and reboot abort in-flight on rescue quorum loss"
}

test_boot_b_only_neutralizes_ambient_dtbo() {
  local case_dir=""
  local restore_sha=""

  case_dir="$(new_case ambient-dtbo)"
  printf 'ambient-dtbo-payload\n' > "$case_dir/ambient-dtbo.img"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  export RESTORE_DTBO_IMAGE="$case_dir/ambient-dtbo.img"
  export RESTORE_DTBO_SHA256
  RESTORE_DTBO_SHA256="$(sha256sum "$RESTORE_DTBO_IMAGE" | awk '{ print $1 }')"
  start_mock_contract_watcher "$case_dir" "$case_dir/restore.img" "$restore_sha" normal \
    "$ROOT/scripts/rescue-boot-b-when-visible.sh"
  unset RESTORE_DTBO_IMAGE RESTORE_DTBO_SHA256

  grep -Fxq 'boot_b_only=1' "$MOCK_CONTRACT_READY" || fail "primary watcher did not attest boot_b-only scope"
  grep -Fxq 'restore_dtbo_image=none' "$MOCK_CONTRACT_READY" || fail "primary watcher retained ambient dtbo"
  grep -Fxq 'restore_dtbo_sha256=none' "$MOCK_CONTRACT2_READY" || fail "backup watcher retained ambient dtbo hash"
  tr '\0' '\n' < "/proc/$MOCK_CONTRACT_PID/cmdline" | grep -Fxq -- '--boot-b-only' ||
    fail "primary watcher cmdline lacks --boot-b-only"
  ! tr '\0' '\n' < "/proc/$MOCK_CONTRACT_PID/cmdline" | grep -Fxq -- '--restore-dtbo-b' ||
    fail "primary watcher received an implicit dtbo restore option"
  [ ! -s "$case_dir/fastboot-writes.log" ] || fail "ambient dtbo reached a fastboot write"
  kill_case_watchers "$case_dir"
  pass "boot_b-only watcher contracts neutralize ambient DTBO image and hash"
}

test_legacy_dtbo_requires_live_hash_pin() {
  local case_dir=""
  local restore_sha=""
  local dtbo_sha=""
  local status=0
  local watcher_file="$ROOT/scripts/rescue-boot-b-when-visible.sh"
  local restore_body=""
  local final_hash_line=""
  local dtbo_flash_line=""

  case_dir="$(new_case dtbo-missing-hash)"
  printf 'explicit-dtbo\n' > "$case_dir/dtbo.img"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  set +e
  helper_env "$case_dir" \
    "$ROOT/scripts/rescue-boot-b-when-visible.sh" \
    --serial "$SERIAL" \
    --restore-boot-b "$case_dir/restore.img" \
    --restore-boot-b-sha256 "$restore_sha" \
    --restore-dtbo-b "$case_dir/dtbo.img" \
    --after-restore none --timeout 2 --poll 1 > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "unhashed explicit DTBO returned $status instead of 2"
  grep -q -- '--restore-dtbo-b requires --restore-dtbo-b-sha256' "$case_dir/output.log" ||
    fail "missing DTBO hash was not diagnosed"
  [ ! -s "$case_dir/fastboot-writes.log" ] || fail "unhashed DTBO reached fastboot"

  case_dir="$(new_case dtbo-mutated-before-flash)"
  printf 'fastboot\n' > "$case_dir/state"
  printf 'explicit-dtbo\n' > "$case_dir/dtbo.img"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  dtbo_sha="$(sha256sum "$case_dir/dtbo.img" | awk '{ print $1 }')"
  set +e
  helper_env "$case_dir" MUTATE_DTBO_PATH="$case_dir/dtbo.img" \
    "$ROOT/scripts/rescue-boot-b-when-visible.sh" \
    --serial "$SERIAL" \
    --restore-boot-b "$case_dir/restore.img" \
    --restore-boot-b-sha256 "$restore_sha" \
    --restore-dtbo-b "$case_dir/dtbo.img" \
    --restore-dtbo-b-sha256 "$dtbo_sha" \
    --after-restore none --timeout 2 --poll 1 > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "mutated explicit DTBO returned $status instead of 3"
  [ -e "$case_dir/dtbo-mutated" ] || fail "DTBO mutation boundary was not exercised"
  grep -q 'dtbo image hash mismatch' "$case_dir/output.log" || fail "mutated DTBO hash was not revalidated"
  ! grep -q '^FLASH dtbo_b$' "$case_dir/fastboot-writes.log" || fail "mutated DTBO reached dtbo_b"
  ! grep -q '^FLASH boot_b$' "$case_dir/fastboot-writes.log" || fail "DTBO failure fell through to boot_b"
  restore_body="$(sed -n '/^restore_from_fastboot()/,/^}/p' "$watcher_file")"
  final_hash_line="$(grep -n 'verify_restore_dtbo_hash || return 1' <<< "$restore_body" | tail -n 1 | cut -d: -f1)"
  dtbo_flash_line="$(grep -n 'fastboot_do flash dtbo_b' <<< "$restore_body" | cut -d: -f1)"
  [ -n "$final_hash_line" ] && [ -n "$dtbo_flash_line" ] && [ "$final_hash_line" -lt "$dtbo_flash_line" ] ||
    fail "DTBO hash is not revalidated at the final fastboot flash boundary"
  pass "legacy DTBO restore requires and revalidates an explicit SHA256 immediately before flash"
}

test_writer_contract_rejections() {
  local case_dir=""
  local expected_sha=""
  local restore_sha=""
  local status=0
  local fake_pid=""
  local fake_starttime=""
  local stale_starttime=""
  local nonce=""
  local ready=""
  local challenge=""
  local ack=""
  local -a contract_args=()

  case_dir="$(new_case contract-missing)"
  expected_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  set +e
  helper_env "$case_dir" "$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
    --image "$case_dir/test.img" \
    --image-sha256 "$expected_sha" \
    --serial "$SERIAL" \
    --host 172.16.42.1 \
    --user user \
    --password password \
    --require-watcher-contract \
    --required-watcher-pid "$$" \
    > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "incomplete mandatory watcher contract returned $status instead of 2"
  [ ! -s "$case_dir/remote-writer-invocations" ] || fail "incomplete contract reached remote writer"

  case_dir="$(new_case contract-fake-sleep)"
  expected_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  start_mock_contract_watcher "$case_dir" "$case_dir/restore.img" "$restore_sha"
  nonce="$(printf '%s' "$case_dir" | sha256sum | awk '{ print $1 }')"
  ready="$case_dir/forged.ready"
  challenge="$case_dir/forged.challenge"
  ack="$case_dir/forged.ack"
  sleep 30 &
  fake_pid=$!
  printf '%s\n' "$fake_pid" >> "$case_dir/watcher.pids"
  fake_starttime="$(proc_starttime "$fake_pid")"
  write_forged_contract_ready "$ready" "$fake_pid" "$fake_starttime" \
    "$MOCK_BIN/mock-watcher" "$case_dir/restore.img" "$restore_sha" "$nonce" "$challenge" "$ack"
  contract_args=(
    --required-watcher-pid "$fake_pid"
    --required-watcher-starttime "$fake_starttime"
    --required-watcher-ready-file "$ready"
    --required-watcher-nonce "$nonce"
    --required-watcher-script "$MOCK_BIN/mock-watcher"
    --required-watcher-restore-image "$case_dir/restore.img"
    --required-watcher-restore-sha256 "$restore_sha"
    --required-watcher-challenge-file "$challenge"
    --required-watcher-ack-file "$ack"
  )
  set +e
  helper_env "$case_dir" "$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
    --image "$case_dir/test.img" --image-sha256 "$expected_sha" \
    --serial "$SERIAL" --host 172.16.42.1 --user user --password password \
    "${MOCK_CONTRACT_ARGS[@]}" "${contract_args[@]}" > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  kill "$fake_pid" 2>/dev/null || true
  wait "$fake_pid" 2>/dev/null || true
  [ "$status" -eq 3 ] || fail "forged sleep watcher returned $status instead of 3"
  [ ! -s "$case_dir/remote-writer-invocations" ] || fail "forged sleep reached remote writer"

  case_dir="$(new_case contract-stale-starttime)"
  expected_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  start_mock_contract_watcher "$case_dir" "$case_dir/restore.img" "$restore_sha"
  nonce="$(printf '%s' "$case_dir" | sha256sum | awk '{ print $1 }')"
  ready="$case_dir/stale.ready"
  challenge="$case_dir/stale.challenge"
  ack="$case_dir/stale.ack"
  sleep 30 &
  fake_pid=$!
  printf '%s\n' "$fake_pid" >> "$case_dir/watcher.pids"
  fake_starttime="$(proc_starttime "$fake_pid")"
  stale_starttime=$((fake_starttime + 1))
  write_forged_contract_ready "$ready" "$fake_pid" "$stale_starttime" \
    sleep "$case_dir/restore.img" "$restore_sha" "$nonce" "$challenge" "$ack"
  contract_args=(
    --required-watcher-pid "$fake_pid"
    --required-watcher-starttime "$stale_starttime"
    --required-watcher-ready-file "$ready"
    --required-watcher-nonce "$nonce"
    --required-watcher-script sleep
    --required-watcher-restore-image "$case_dir/restore.img"
    --required-watcher-restore-sha256 "$restore_sha"
    --required-watcher-challenge-file "$challenge"
    --required-watcher-ack-file "$ack"
  )
  set +e
  helper_env "$case_dir" "$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
    --image "$case_dir/test.img" --image-sha256 "$expected_sha" \
    --serial "$SERIAL" --host 172.16.42.1 --user user --password password \
    "${MOCK_CONTRACT_ARGS[@]}" "${contract_args[@]}" > "$case_dir/output.log" 2>&1
  status=$?
  set -e
  kill "$fake_pid" 2>/dev/null || true
  wait "$fake_pid" 2>/dev/null || true
  [ "$status" -eq 3 ] || fail "stale starttime contract returned $status instead of 3"
  [ ! -s "$case_dir/remote-writer-invocations" ] || fail "stale PID contract reached remote writer"
  pass "writer rejects missing, forged-process and stale-PID watcher contracts"
}

test_real_helper_contract_fields() {
  local field=""
  local case_dir=""
  local expected_sha=""
  local restore_sha=""
  local serial_arg=""
  local status=0
  local mode=""
  local replacement=""
  local -a overrides=()

  for field in ready starttime cmdline serial restore hash nonce ACK; do
    case_dir="$(new_case "contract-field-$field")"
    expected_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
    restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
    serial_arg="$SERIAL"
    mode=normal
    overrides=()
    [ "$field" != "ACK" ] || mode=ignore-ack-1
    start_mock_contract_watcher "$case_dir" "$case_dir/restore.img" "$restore_sha" "$mode"

    case "$field" in
      ready)
        printf 'tampered=1\n' >> "$MOCK_CONTRACT_READY"
        ;;
      starttime)
        overrides+=(--required-watcher-starttime "$((MOCK_CONTRACT_STARTTIME + 1))")
        ;;
      cmdline)
        overrides+=(--required-watcher-script /bin/false)
        ;;
      serial)
        serial_arg="WRONG-SERIAL"
        ;;
      restore)
        printf 'other-restore\n' > "$case_dir/other-restore.img"
        overrides+=(
          --required-watcher-restore-image "$case_dir/other-restore.img"
          --required-watcher2-restore-image "$case_dir/other-restore.img"
        )
        ;;
      hash)
        replacement="$(printf 'wrong-restore-hash' | sha256sum | awk '{ print $1 }')"
        overrides+=(
          --required-watcher-restore-sha256 "$replacement"
          --required-watcher2-restore-sha256 "$replacement"
        )
        ;;
      nonce)
        replacement="$(printf 'wrong-contract-nonce' | sha256sum | awk '{ print $1 }')"
        overrides+=(--required-watcher-nonce "$replacement")
        ;;
      ACK) ;;
    esac

    set +e
    helper_env "$case_dir" WATCHER_CONTRACT_ACK_TIMEOUT_SEC=1 \
      "$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
      --image "$case_dir/test.img" \
      --image-sha256 "$expected_sha" \
      --serial "$serial_arg" \
      --host 172.16.42.1 \
      --user user \
      --password password \
      "${MOCK_CONTRACT_ARGS[@]}" \
      "${overrides[@]}" \
      > "$case_dir/output.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 3 ] || fail "real helper accepted bad $field contract field with status $status"
    [ ! -s "$case_dir/remote-writer-invocations" ] || fail "bad $field field reached remote writer"
    kill_case_watchers "$case_dir"
  done
  pass "real helper rejects ready/starttime/cmdline/serial/restore/hash/nonce/ACK corruption"
}

test_watcher_dies_between_ensure_and_writer() {
  local case_dir=""
  local image_sha=""
  local restore_sha=""
  local status=0

  case_dir="$(new_case watcher-ensure-args-race)"
  printf 'die-at-writer-entry\n' > "$case_dir/watcher-mode"
  image_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  set +e
  helper_env "$case_dir" \
    "$ROOT/scripts/test-boot-b-image.sh" \
    --image "$case_dir/test.img" \
    --image-sha256 "$image_sha" \
    --restore-boot-b "$case_dir/restore.img" \
    --restore-boot-b-sha256 "$restore_sha" \
    --serial "$SERIAL" \
    --from-pmos-ssh \
    --start-rescue-watcher \
    --require-dirty-survival \
    --restore-after system \
    --boot-wait 3 \
    --poll 1 \
    --rescue-watch-timeout 30 \
    --rescue-watch-poll 1 \
    > "$case_dir/output.log" 2>&1
  status=$?
  set -e

  [ "$status" -eq 4 ] || fail "ensure-to-writer watcher death returned $status instead of 4"
  grep -q 'mandatory-contract-rejected-dead' "$case_dir/output.log" ||
    fail "ensure-to-writer watcher death did not reach mandatory writer contract"
  [ ! -s "$case_dir/remote-writer-invocations" ] || fail "ensure-to-writer death reached remote dd/readback"
  [ ! -e "$case_dir/reboot-called" ] || fail "ensure-to-writer death reached reboot"
  assert_live_current_watcher "$case_dir"
  pass "watcher death between ensure and writer remains contract-bound and write-free"
}

test_old_source_rolls_back() {
  local case_dir=""

  case_dir="$(new_case old-source)"
  printf 'stay-source\n' > "$case_dir/writer-behavior"
  if run_ssh_case "$case_dir" "$case_dir/output.log"; then
    fail "unchanged source boot_id was reported as success"
  fi
  grep -q '^kind=restore ' "$case_dir/writer.log" || fail "unchanged source did not invoke strict SSH rollback"
  grep -q 'Strict source-SSH rollback readback verified' "$case_dir/output.log" || fail "rollback readback was not recorded"
  pass "unchanged source boot_id triggers strict SSH rollback"
}

test_err_after_dirty_keeps_watcher() {
  local case_dir=""
  local image_sha=""
  local restore_sha=""

  case_dir="$(new_case err-dirty)"
  printf 'fastboot\n' > "$case_dir/state"
  printf 'fail\n' > "$case_dir/fastboot-behavior"
  image_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  if helper_env "$case_dir" "$ROOT/scripts/test-boot-b-image.sh" \
    --image "$case_dir/test.img" --image-sha256 "$image_sha" \
    --restore-boot-b "$case_dir/restore.img" --restore-boot-b-sha256 "$restore_sha" \
    --serial "$SERIAL" --start-rescue-watcher --boot-wait 2 --poll 1 \
    > "$case_dir/output.log" 2>&1; then
    fail "failed direct fastboot write returned success"
  fi
  assert_live_current_watcher "$case_dir"
  pass "ERR after dirty preserves a live watcher"
}

test_ctrl_c_after_dirty_keeps_watcher() {
  local case_dir=""
  local image_sha=""
  local restore_sha=""
  local runner=""

  case_dir="$(new_case ctrl-c)"
  printf 'sleep\n' > "$case_dir/writer-behavior"
  image_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  runner="$case_dir/ctrl-c-runner.sh"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nexec env '
    printf '%q ' \
      "PATH=$MOCK_BIN:/usr/bin:/bin" \
      "HOTDOG_ROOT=$ROOT" \
      "HOTDOG_LOCAL_ENV=$case_dir/no-local-env" \
      "HOTDOG_LOG_ROOT=$case_dir/logs" \
      "HOTDOG_TARGET_SERIAL=$SERIAL" \
      "ANDROID_SERIAL=$SERIAL" \
      "HOTDOG_PMOS_HOST=172.16.42.1" \
      "HOTDOG_PMOS_USER=user" \
      "HOTDOG_PMOS_PASSWORD=password" \
      "HOTDOG_FLASH_BOOT_B_SSH_HELPER=$MOCK_BIN/mock-writer" \
      "HOTDOG_RESCUE_WATCHER_HELPER=$MOCK_BIN/mock-watcher" \
      "HOTDOG_FORCE_RESCUE_FALLBACK=1" \
      "MOCK_STATE_DIR=$case_dir" \
      "SERIAL=$SERIAL" \
      "SOURCE_BOOT_ID=$SOURCE_BOOT_ID" \
      "SOURCE_KERNEL=$SOURCE_KERNEL" \
      "SOURCE_CMDLINE=$SOURCE_CMDLINE" \
      "TARGET_BOOT_ID=$TARGET_BOOT_ID" \
      "TARGET_KERNEL=$TARGET_KERNEL" \
      "TARGET_CMDLINE=$TARGET_CMDLINE" \
      "$ROOT/scripts/test-boot-b-image.sh" \
      --image "$case_dir/test.img" \
      --image-sha256 "$image_sha" \
      --restore-boot-b "$case_dir/restore.img" \
      --restore-boot-b-sha256 "$restore_sha" \
      --serial "$SERIAL" \
      --from-pmos-ssh \
      --start-rescue-watcher \
      --expect-source-kernel-prefix 4.14.357-openela-perf \
      --expect-source-cmdline-token androidboot.slot_suffix=_b \
      --expect-source-cmdline-token "androidboot.serialno=$SERIAL" \
      --expect-kernel-prefix 6.17.0-sm8150 \
      --expect-cmdline-token rdinit=/hotdog-mainline-wrapper \
      --expect-cmdline-token androidboot.slot_suffix=_b \
      --expect-cmdline-token "androidboot.serialno=$SERIAL" \
      --restore-after system \
      --boot-wait 3 \
      --poll 1 \
      --fastboot-timeout 2 \
      --rescue-watch-timeout 30 \
      --rescue-watch-poll 1
    printf '\n'
  } > "$runner"
  chmod 755 "$runner"

  python3 - "$runner" "$case_dir/writer-entered" "$case_dir/output.log" <<'PY'
import os
import pty
import select
import signal
import sys
import time

runner, entered, output = sys.argv[1:]
pid, master = pty.fork()
if pid == 0:
    os.execv(runner, [runner])

captured = bytearray()


def drain(timeout=0):
    while True:
        readable, _, _ = select.select([master], [], [], timeout)
        if not readable:
            return
        try:
            chunk = os.read(master, 65536)
        except OSError:
            return
        if not chunk:
            return
        captured.extend(chunk)
        timeout = 0


deadline = time.monotonic() + 8
while not os.path.exists(entered) and time.monotonic() < deadline:
    drain(0.05)
if not os.path.exists(entered):
    os.killpg(pid, signal.SIGTERM)
    raise SystemExit("dirty writer was not reached")

os.write(master, b"\x03")
deadline = time.monotonic() + 8
exited = False
while time.monotonic() < deadline:
    drain(0.05)
    waited, _ = os.waitpid(pid, os.WNOHANG)
    if waited == pid:
        exited = True
        break
if not exited:
    os.killpg(pid, signal.SIGTERM)
    os.waitpid(pid, 0)
    raise SystemExit("Ctrl-C did not terminate the orchestrator")

drain(0)
with open(output, "wb") as output_file:
    output_file.write(captured)
PY
  assert_live_current_watcher "$case_dir"
  pass "Ctrl-C after dirty preserves a live watcher"
}

test_dead_watcher_rearmed() {
  local case_dir=""
  local count=""

  case_dir="$(new_case watcher-dead)"
  printf 'kill-primary-after-candidate-write\n' > "$case_dir/watcher-mode"
  printf 'success-no-usb\n' > "$case_dir/writer-behavior"
  if run_ssh_case "$case_dir" "$case_dir/output.log"; then
    fail "no-USB timeout unexpectedly succeeded"
  fi
  count="$(cat "$case_dir/watcher.count")"
  [ "$count" -ge 2 ] || fail "dead watcher was not rearmed (count=$count)"
  assert_live_current_watcher "$case_dir"
  pass "dead watcher is rearmed with a new handshake"
}

run_rescue_rejection_case() {
  local case_dir="$1"
  shift
  local expected_sha=""
  local -a overrides=("$@")

  expected_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  helper_env "$case_dir" "${overrides[@]}" HOTDOG_RESCUE_LOG_TEE=0 "$ROOT/scripts/rescue-boot-b-when-visible.sh" \
    --serial "$SERIAL" \
    --restore-boot-b "$case_dir/restore.img" \
    --restore-boot-b-sha256 "$expected_sha" \
    --after-restore none \
    --timeout 2 \
    --poll 1 \
    > "$case_dir/output.log" 2>&1
}

test_wrong_fastboot_identity_refused() {
  local case_dir=""

  case_dir="$(new_case wrong-product)"
  printf 'fastboot\n' > "$case_dir/state"
  if run_rescue_rejection_case "$case_dir" MOCK_FASTBOOT_PRODUCT=guacamole; then
    fail "wrong fastboot product watcher unexpectedly succeeded"
  fi
  [ ! -s "$case_dir/fastboot-writes.log" ] || fail "wrong product reached a fastboot flash"

  case_dir="$(new_case wrong-serial)"
  printf 'fastboot\n' > "$case_dir/state"
  if run_rescue_rejection_case "$case_dir" MOCK_FASTBOOT_GETVAR_SERIAL=serial123; then
    fail "wrong fastboot serial watcher unexpectedly succeeded"
  fi
  [ ! -s "$case_dir/fastboot-writes.log" ] || fail "wrong serial reached a fastboot flash"

  case_dir="$(new_case locked-fastboot)"
  printf 'fastboot\n' > "$case_dir/state"
  if run_rescue_rejection_case "$case_dir" MOCK_FASTBOOT_UNLOCKED=no; then
    fail "locked fastboot watcher unexpectedly succeeded"
  fi
  [ ! -s "$case_dir/fastboot-writes.log" ] || fail "locked target reached a fastboot flash"
  pass "wrong fastboot product, serial and locked state never reach flash"
}

test_multiple_fastboot_devices_refused() {
  local case_dir=""
  local image_sha=""
  local restore_sha=""

  case_dir="$(new_case multiple-fastboot)"
  printf 'fastboot\n' > "$case_dir/state"
  image_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  if helper_env "$case_dir" HOTDOG_TARGET_SERIAL= ANDROID_SERIAL= \
    MOCK_FASTBOOT_SECOND_SERIAL=OTHER \
    "$ROOT/scripts/test-boot-b-image.sh" \
    --image "$case_dir/test.img" --image-sha256 "$image_sha" \
    --restore-boot-b "$case_dir/restore.img" --restore-boot-b-sha256 "$restore_sha" \
    --boot-wait 2 --poll 1 > "$case_dir/output.log" 2>&1; then
    fail "multiple fastboot devices were auto-selected"
  fi
  grep -q 'Multiple fastboot devices found' "$case_dir/output.log" ||
    fail "multiple-device refusal was not diagnosed"
  [ ! -s "$case_dir/fastboot-writes.log" ] || fail "multiple-device case reached a fastboot flash"
  pass "multiple fastboot devices require an explicit serial"
}

test_restore_hash_mutation_refused() {
  local case_dir=""

  case_dir="$(new_case restore-hash-mutation)"
  printf 'mutate-restore-stay-source\n' > "$case_dir/writer-behavior"
  if run_ssh_case "$case_dir" "$case_dir/output.log"; then
    fail "mutated restore image unexpectedly produced success"
  fi
  ! grep -q '^kind=restore ' "$case_dir/writer.log" ||
    fail "mutated restore image reached the remote writer"
  grep -q 'Source-SSH rollback refused: restore image hash changed' "$case_dir/output.log" ||
    fail "mutated restore hash refusal was not diagnosed"
  assert_live_current_watcher "$case_dir"
  pass "restore hash mutation is refused and rescue remains armed"
}

test_recovery_after_restore_not_reflashed() {
  local case_dir=""
  local expected_sha=""
  local write_count=""

  case_dir="$(new_case recovery-hold)"
  printf 'fastboot\n' > "$case_dir/state"
  expected_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  if helper_env "$case_dir" MOCK_REBOOT_STATE=recovery HOTDOG_RESCUE_LOG_TEE=0 \
    "$ROOT/scripts/rescue-boot-b-when-visible.sh" \
    --serial "$SERIAL" \
    --restore-boot-b "$case_dir/restore.img" \
    --restore-boot-b-sha256 "$expected_sha" \
    --after-restore recovery \
    --timeout 3 \
    --poll 1 > "$case_dir/output.log" 2>&1; then
    fail "finite recovery-hold watcher unexpectedly succeeded"
  fi
  write_count="$(grep -c '^FLASH boot_b$' "$case_dir/fastboot-writes.log" || true)"
  [ "$write_count" -eq 1 ] || fail "accepted recovery restore was flashed $write_count times"
  pass "accepted restore returning to recovery is not reflashed in a loop"
}

test_hash_mutation_refused() {
  local case_dir=""
  local expected_sha=""

  case_dir="$(new_case hash-mutation)"
  expected_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  if helper_env "$case_dir" MUTATE_IMAGE_PATH="$case_dir/test.img" \
    "$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh" \
    --image "$case_dir/test.img" \
    --image-sha256 "$expected_sha" \
    --serial "$SERIAL" \
    --host 172.16.42.1 \
    --user user \
    --password password \
    --expected-source-boot-id "$SOURCE_BOOT_ID" \
    --expected-source-kernel "$SOURCE_KERNEL" \
    --expected-source-cmdline-token androidboot.slot_suffix=_b \
    > "$case_dir/output.log" 2>&1; then
    fail "mutated image reached writer success"
  fi
  grep -q 'Local image changed before transfer' "$case_dir/output.log" || fail "hash mutation was not caught before transfer"
  pass "image mutation after initial hash is refused before transfer"
}

test_source_stale_attestation() {
  local case_dir=""
  local writer_file=""
  local first_assert=""
  local dd_line=""
  local remote_writer_body=""

  case_dir="$(new_case stale-source)"
  printf 'stale-source\n' > "$case_dir/writer-behavior"
  if run_ssh_case "$case_dir" "$case_dir/output.log"; then
    fail "stale source writer unexpectedly succeeded"
  fi
  grep -q 'kind=restore ' "$case_dir/writer.log" || fail "stale source did not enter conservative rollback"
  grep -q 'boot_id=source-boot-id kernel=4.14.357-openela-perf' "$case_dir/writer.log" ||
    fail "source boot_id/kernel were not propagated to writer"
  writer_file="$ROOT/scripts/flash-boot-b-from-pmos-ssh.sh"
  first_assert="$(grep -n '^assert_peer_identity$' "$writer_file" | tail -n 1 | cut -d: -f1)"
  dd_line="$(grep -n 'dd if="\$img" of="\$part_real"' "$writer_file" | cut -d: -f1)"
  [ -n "$first_assert" ] && [ -n "$dd_line" ] && [ "$first_assert" -lt "$dd_line" ] ||
    fail "writer does not reassert source identity immediately before dd"
  remote_writer_body="$(sed -n "/^  ssh_base .*<<'REMOTE_SCRIPT'/,/^REMOTE_SCRIPT$/p" "$writer_file")"
  grep -Fq 'part_link_now="$(readlink -f "$part"' <<< "$remote_writer_body" ||
    fail "remote writer does not freeze and recheck the boot_b symlink target"
  grep -Fq 'of="$part_real"' <<< "$remote_writer_body" || fail "remote writer does not write through part_real"
  grep -Fq 'dd if="$part_real"' <<< "$remote_writer_body" || fail "remote writer does not read back through part_real"
  ! grep -Fq 'of="$part"' <<< "$remote_writer_body" || fail "remote writer still writes through the mutable symlink"
  ! grep -Fq 'dd if="$part"' <<< "$remote_writer_body" || fail "remote writer still reads through the mutable symlink"
  pass "stale source is rejected and final write/readback stay on the validated part_real device"
}

test_concurrent_lock() {
  local case_dir=""
  local holder=""

  case_dir="$(new_case lock)"
  HOTDOG_LOG_ROOT="$case_dir/logs" bash -c '
    set -Eeuo pipefail
    source "$1"
    phone_lock_acquire holder 0
    : > "$2"
    sleep 2
    phone_lock_release
  ' _ "$ROOT/scripts/phone-lock.sh" "$case_dir/lock-ready" > "$case_dir/holder.log" 2>&1 &
  holder=$!
  for _ in {1..30}; do
    [ -e "$case_dir/lock-ready" ] && break
    sleep 0.1
  done
  [ -e "$case_dir/lock-ready" ] || fail "lock holder did not initialize"
  if HOTDOG_LOG_ROOT="$case_dir/logs" bash -c '
    set -Eeuo pipefail
    source "$1"
    phone_lock_acquire contender 0
  ' _ "$ROOT/scripts/phone-lock.sh" > "$case_dir/contender.log" 2>&1; then
    fail "concurrent contender acquired the held flock"
  fi
  wait "$holder"
  pass "concurrent phone lock acquisition is excluded by flock"
}

test_dirty_policy_requires_prearmed_watcher() {
  local mode=""
  local case_dir=""
  local image_sha=""
  local restore_sha=""
  local status=0
  local -a policy_args=()

  for mode in explicit strict-derived; do
    case_dir="$(new_case "dirty-policy-no-watcher-$mode")"
    image_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
    restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
    policy_args=()
    case "$mode" in
      explicit) policy_args+=(--require-dirty-survival) ;;
      strict-derived) policy_args+=(--expect-kernel-prefix 6.17.0-sm8150) ;;
    esac

    set +e
    helper_env "$case_dir" "$ROOT/scripts/test-boot-b-image.sh" \
      --image "$case_dir/test.img" \
      --image-sha256 "$image_sha" \
      --restore-boot-b "$case_dir/restore.img" \
      --restore-boot-b-sha256 "$restore_sha" \
      --serial "$SERIAL" \
      "${policy_args[@]}" \
      --boot-wait 2 --poll 1 > "$case_dir/output.log" 2>&1
    status=$?
    set -e

    [ "$status" -eq 2 ] || fail "$mode dirty policy without watcher returned $status instead of 2"
    grep -q 'Dirty-survival policy requires --start-rescue-watcher before any phone access' \
      "$case_dir/output.log" || fail "$mode dirty policy refusal was not diagnosed"
    [ ! -s "$case_dir/phone-access.log" ] || fail "$mode dirty policy touched adb/fastboot/SSH before refusal"
    [ ! -s "$case_dir/writer.log" ] || fail "$mode dirty policy reached the SSH writer"
    [ ! -e "$case_dir/logs/phone-operation.lock.flock" ] || fail "$mode dirty policy created the flock file"
    [ ! -e "$case_dir/logs/phone-operation.lock" ] || fail "$mode dirty policy created phone-lock ownership metadata"
    ! grep -Rqs 'Phone operation lock acquired' "$case_dir/logs" "$case_dir/output.log" ||
      fail "$mode dirty policy acquired the phone lock before refusal"
  done
  pass "explicit and strict-derived dirty policies refuse code 2 before phone or lock access without a watcher"
}

test_dirty_recovery_fastbootd_handoff_watcher_guard() {
  local case_dir=""
  local watcher_count=0
  local status=0

  case_dir="$(new_case dirty-recovery-fastbootd-quorum-death)"
  printf 'success-recovery\n' > "$case_dir/writer-behavior"
  set +e
  run_ssh_case "$case_dir" "$case_dir/output.log" \
    MOCK_ADB_BOOTLOADER_STATE=fastboot \
    MOCK_FASTBOOT_USERSPACE=yes \
    MOCK_FASTBOOT_KILL_ON=fastbootd-reboot
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "dirty recovery-to-fastbootd quorum death returned $status instead of 3"
  grep -q '^kind=candidate ' "$case_dir/writer.log" || fail "dirty fastbootd case never accepted the SSH candidate write"
  ! grep -q '^kind=restore ' "$case_dir/writer.log" || fail "dirty fastbootd case incorrectly completed an SSH restore"
  grep -q "ADB mode 'recovery' visible after boot attempt" "$case_dir/output.log" ||
    fail "dirty fastbootd case did not enter the recovery fallback"
  grep -q '^adb -s SERIAL123 reboot bootloader$' "$case_dir/phone-access.log" ||
    fail "recovery fallback did not request its bootloader handoff"
  [ -e "$case_dir/fastboot-fastbootd-reboot-entered" ] || fail "fastbootd guarded handoff was not entered"
  [ ! -e "$case_dir/fastboot-fastbootd-reboot-dispatched" ] || fail "fastbootd handoff dispatched after quorum death"
  [ ! -e "$case_dir/fastbootd-left" ] || fail "failed fastbootd reboot was accepted as a completed bootloader handoff"
  [ ! -s "$case_dir/fastboot-writes.log" ] || fail "failed fastbootd handoff reached the restore flash"
  grep -q 'rescue pair degraded during fastbootd bootloader reboot' "$case_dir/output.log" ||
    fail "fastbootd quorum loss was not diagnosed"
  watcher_count="$(cat "$case_dir/watcher.count")"
  [ "$watcher_count" -ge 3 ] || fail "fastbootd quorum loss did not attempt watcher rearm (count=$watcher_count)"
  assert_live_current_watcher "$case_dir"
  pass "dirty candidate recovery fallback aborts fastbootd handoff on quorum loss and rearms rescue"
}

test_fastbootd_legacy_clean_no_watcher() {
  local case_dir=""
  local image_sha=""
  local restore_sha=""

  case_dir="$(new_case fastbootd-legacy-no-watcher)"
  printf 'fastboot\n' > "$case_dir/state"
  image_sha="$(sha256sum "$case_dir/test.img" | awk '{ print $1 }')"
  restore_sha="$(sha256sum "$case_dir/restore.img" | awk '{ print $1 }')"
  helper_env "$case_dir" MOCK_FASTBOOT_USERSPACE=yes MOCK_REBOOT_STATE=target \
    "$ROOT/scripts/test-boot-b-image.sh" \
    --image "$case_dir/test.img" \
    --image-sha256 "$image_sha" \
    --restore-boot-b "$case_dir/restore.img" \
    --restore-boot-b-sha256 "$restore_sha" \
    --serial "$SERIAL" \
    --restore-after system \
    --boot-wait 3 --poll 1 --fastboot-timeout 2 \
    > "$case_dir/output.log" 2>&1 || fail "legacy fastbootd handoff without watcher returned nonzero"
  [ -e "$case_dir/fastboot-fastbootd-reboot-dispatched" ] || fail "legacy fastbootd handoff was not dispatched"
  grep -q '^FLASH boot_b$' "$case_dir/fastboot-writes.log" || fail "legacy fastbootd route did not retain candidate flow"
  grep -q 'Legacy generic result contract' "$case_dir/output.log" || fail "legacy fastbootd route lost its historical result contract"
  assert_no_live_case_watchers "$case_dir"
  pass "initial clean fastbootd handoff remains legacy-compatible without a watcher"
}

test_launchers_reject_timing() {
  local output=""
  local status=0

  set +e
  output="$(HOTDOG_ROOT="$ROOT" HOTDOG_LOCAL_ENV="$TMP/no-env" \
    "$ROOT/scripts/test-mainline617-direct-d1.sh" --poll 99 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 2 ] && [[ "$output" == *"Unsupported option for pinned D1 test"* ]] || fail "D1 launcher accepted --poll"

  set +e
  output="$(HOTDOG_ROOT="$ROOT" HOTDOG_LOCAL_ENV="$TMP/no-env" \
    "$ROOT/scripts/test-mainline617-direct-d1-pack.sh" --rescue-watch-timeout 1 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 2 ] && [[ "$output" == *"Unsupported option for pinned D1-pack test"* ]] || fail "D1-pack launcher accepted rescue timeout"
  grep -q -- '--require-dirty-survival' "$ROOT/scripts/test-mainline617-direct-d1.sh" ||
    fail "D1 launcher does not pin dirty-survival policy"
  grep -q -- '--require-dirty-survival' "$ROOT/scripts/test-mainline617-direct-d1-pack.sh" ||
    fail "D1-pack launcher does not pin dirty-survival policy"
  pass "D1 launchers reject all timing overrides"
}

test_launchers_reject_serial_divergence() {
  local launcher=""
  local name=""
  local case_dir=""
  local status=0

  for launcher in \
    "$ROOT/scripts/test-lineage414-r5-kexec-bridge.sh" \
    "$ROOT/scripts/test-mainline617-direct-d1.sh" \
    "$ROOT/scripts/test-mainline617-direct-d1-pack.sh"
  do
    name="$(basename "$launcher" .sh)"
    case_dir="$(new_case "serial-divergence-$name")"
    set +e
    helper_env "$case_dir" ANDROID_SERIAL=OTHER-SERIAL \
      "$launcher" > "$case_dir/output.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail "$name serial divergence returned $status instead of 2"
    grep -q 'differs from HOTDOG_TARGET_SERIAL' "$case_dir/output.log" ||
      fail "$name did not diagnose the serial divergence"
    [ ! -s "$case_dir/writer.log" ] || fail "$name reached a writer with divergent serials"
    [ ! -s "$case_dir/fastboot.log" ] || fail "$name reached fastboot with divergent serials"
  done
  pass "R5, D1 and D1-pack refuse divergent ANDROID_SERIAL identities before transport"
}

test_strict_success_contract
test_atomic_ack_peer_flip_refused
test_legacy_generic_no_rescue_contract
test_lineage_bridge_strict_contract
test_watcher_dies_after_remote_readback
test_ssh_ack_transport_windows
test_ssh_reboot_dispatch_proof
test_fastboot_ack_transport_windows
test_restore_fastboot_transport_windows
test_boot_b_only_neutralizes_ambient_dtbo
test_legacy_dtbo_requires_live_hash_pin
test_writer_contract_rejections
test_real_helper_contract_fields
test_watcher_dies_between_ensure_and_writer
test_old_source_rolls_back
test_err_after_dirty_keeps_watcher
test_ctrl_c_after_dirty_keeps_watcher
test_dead_watcher_rearmed
test_wrong_fastboot_identity_refused
test_multiple_fastboot_devices_refused
test_hash_mutation_refused
test_restore_hash_mutation_refused
test_recovery_after_restore_not_reflashed
test_source_stale_attestation
test_concurrent_lock
test_dirty_policy_requires_prearmed_watcher
test_dirty_recovery_fastbootd_handoff_watcher_guard
test_fastbootd_legacy_clean_no_watcher
test_launchers_reject_timing
test_launchers_reject_serial_divergence

log "All $PASS_COUNT offline D1 safety tests passed"
