#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

PMOS_HOST="${PMOS_HOST:-auto}"
PMOS_DEFAULT_HOST="${PMOS_DEFAULT_HOST:-172.16.42.1}"
PMOS_USER="${PMOS_USER:-user}"
PMOS_PASSWORD="${PMOS_PASSWORD:-147147}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"
POLL_SEC="${POLL_SEC:-3}"
stamp="$(date +%F-%H%M%S)"
out="$HOTDOG_LOG_ROOT/pmos-usb-ssh-$stamp"
current_pmos_host=""

usage() {
  cat <<'USAGE'
Usage: wait-pmos-usb-ssh.sh [options]

Wait for postmarketOS USB networking, SSH in, and collect first-boot logs.

Options:
  --host HOST       SSH host or "auto". Default: auto.
  --user USER       SSH user. Default: user.
  --password PASS   SSH password. Default: 147147.
  --timeout SEC     Seconds to wait. Default: 900.
  --poll SEC        Poll interval. Default: 3.
  -h, --help        Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [ "$#" -ge 2 ] || { echo "Missing value for --host" >&2; exit 2; }
      PMOS_HOST="$2"
      shift
      ;;
    --user)
      [ "$#" -ge 2 ] || { echo "Missing value for --user" >&2; exit 2; }
      PMOS_USER="$2"
      shift
      ;;
    --password)
      [ "$#" -ge 2 ] || { echo "Missing value for --password" >&2; exit 2; }
      PMOS_PASSWORD="$2"
      shift
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { echo "Missing value for --timeout" >&2; exit 2; }
      TIMEOUT_SEC="$2"
      shift
      ;;
    --poll)
      [ "$#" -ge 2 ] || { echo "Missing value for --poll" >&2; exit 2; }
      POLL_SEC="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

mkdir -p "$out"
exec > >(tee "$out/run.log") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $1"
  exit "${2:-1}"
}

validate_seconds() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    die "$name must be a positive integer, got: $value" 2
  fi
}

ssh_base() {
  sshpass -p "$PMOS_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$out/known_hosts" \
    -o ConnectTimeout=5 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$PMOS_USER@$current_pmos_host" "$@"
}

try_ssh() {
  ssh_base 'printf "PMOS_SSH_OK\n"; uname -a' > "$out/ssh-probe.txt" 2>&1
}

candidate_hosts() {
  if [ "$PMOS_HOST" != "auto" ]; then
    printf '%s\n' "$PMOS_HOST"
    return 0
  fi

  {
    printf '%s\n' "$PMOS_DEFAULT_HOST"
    ip -o -4 addr show 2>/dev/null | awk '
      {
        split($4, cidr, "/")
        split(cidr[1], o, ".")
        if (o[1] == "172" && o[2] == "16" && o[3] == "42") {
          print "172.16.42.1"
          print "172.16.42.2"
        }
      }
    '
    ip -4 neigh show 2>/dev/null | awk '{ print $1 }' |
      grep -E '^172\.16\.42\.' || true
  } | awk 'NF && !seen[$0]++'
}

collect_logs() {
  log "Collecting postmarketOS first-boot logs"
  printf '%s\n' "$current_pmos_host" > "$out/selected-host.txt"
  ssh_base 'cat /etc/os-release' > "$out/os-release.txt" 2>&1 || true
  ssh_base 'uname -a' > "$out/uname.txt" 2>&1 || true
  ssh_base 'cat /proc/sys/kernel/random/boot_id' > "$out/boot-id.txt" 2>&1 || true
  ssh_base 'ip -br addr; ip route' > "$out/ip.txt" 2>&1 || true
  ssh_base 'mount' > "$out/mounts.txt" 2>&1 || true
  ssh_base 'cat /proc/cmdline' > "$out/cmdline.txt" 2>&1 || true
  ssh_base 'cat /proc/fb 2>&1 || true; echo ---GRAPHICS---; find /sys/class/graphics -maxdepth 2 -type f -print -exec cat {} \; 2>&1 || true; echo ---CONSOLE---; cat /sys/class/tty/console/active 2>&1 || true' > "$out/framebuffer-console.txt" 2>&1 || true
  ssh_base 'dmesg' > "$out/dmesg.txt" 2>&1 || true
  ssh_base 'dmesg | grep -Ei "simple.?fb|fbcon|framebuffer|pstore|ramoops|console|tty0" || true' > "$out/dmesg-display-pstore-grep.txt" 2>&1 || true
  ssh_base 'if command -v sudo >/dev/null 2>&1; then sudo -n sh -c "mkdir -p /sys/fs/pstore; mount -t pstore pstore /sys/fs/pstore 2>/dev/null || true; mount | grep pstore || true; ls -la /sys/fs/pstore 2>&1 || true; for f in /sys/fs/pstore/*; do [ -f \"$f\" ] || continue; echo ---$f---; sed -n \"1,220p\" \"$f\" 2>&1 || true; done"; else mount | grep pstore || true; ls -la /sys/fs/pstore 2>&1 || true; fi' > "$out/pstore.txt" 2>&1 || true
  ssh_base 'find /sys/class/power_supply -maxdepth 2 -type f -print -exec cat {} \;' > "$out/power-supply.txt" 2>&1 || true
  ssh_base 'find /sys/class/net -maxdepth 2 -type f -name address -print -exec cat {} \;' > "$out/net-addresses.txt" 2>&1 || true
  log "Done: $out"
}

main() {
  validate_seconds TIMEOUT_SEC "$TIMEOUT_SEC"
  validate_seconds POLL_SEC "$POLL_SEC"
  command -v ssh >/dev/null 2>&1 || die "Missing ssh" 127
  command -v sshpass >/dev/null 2>&1 || die "Missing sshpass" 127
  command -v ping >/dev/null 2>&1 || die "Missing ping" 127
  command -v ip >/dev/null 2>&1 || die "Missing ip" 127

  log "Run directory: $out"
  log "Waiting for postmarketOS SSH: $PMOS_USER@$PMOS_HOST, timeout ${TIMEOUT_SEC}s"
  if [ "$PMOS_HOST" = "auto" ]; then
    log "Auto candidates start with $PMOS_DEFAULT_HOST and host USB-network neighbours"
  fi

  local deadline=$((SECONDS + TIMEOUT_SEC))
  local last_status=0
  local host=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    ip -br addr > "$out/host-ip-last.txt" 2>&1 || true
    candidate_hosts > "$out/candidate-hosts-last.txt"
    while IFS= read -r host; do
      [ -n "$host" ] || continue
      current_pmos_host="$host"
      if ping -c 1 -W 1 "$host" > "$out/ping-last-$host.txt" 2>&1; then
        log "Ping OK on $host, trying SSH"
        if try_ssh; then
          log "SSH OK on $host"
          collect_logs
          exit 0
        fi
      fi
    done < "$out/candidate-hosts-last.txt"

    if [ $((SECONDS - last_status)) -ge 30 ]; then
      log "Still waiting for SSH; host interfaces:"
      sed 's/^/[ip] /' "$out/host-ip-last.txt" || true
      log "Current SSH candidates:"
      sed 's/^/[candidate] /' "$out/candidate-hosts-last.txt" || true
      last_status=$SECONDS
    fi
    sleep "$POLL_SEC"
  done

  die "Timed out waiting for postmarketOS SSH. See $out" 2
}

main "$@"
