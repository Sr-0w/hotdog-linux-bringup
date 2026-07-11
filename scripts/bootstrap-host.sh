#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
  cat <<'USAGE'
Usage: bootstrap-host.sh [--check-host|--autopilot]

Print a read-only summary of the hotdog workspace and optionally run the
existing host checks. This script never talks to the phone.
USAGE
}

mode="${1:-}"

case "$mode" in
  "")
    ;;
  --check-host)
    ;;
  --autopilot)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $mode" >&2
    usage >&2
    exit 2
    ;;
esac

echo "== hotdog bootstrap =="
printf 'root: %s\n' "$ROOT"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'git:  %s\n' "repo present"
else
  printf 'git:  %s\n' "not initialised yet"
fi

if [ -d "$ROOT/src" ]; then
  subrepo_count="$(find "$ROOT/src" -maxdepth 3 -name .git | wc -l | tr -d ' ')"
else
  subrepo_count=0
fi
printf 'subrepos under src: %s\n' "$subrepo_count"
echo

echo "== key files =="
for path in \
  README.md \
  CONTRIBUTING.md \
  SECURITY.md \
  LICENSE \
  .gitignore \
  .gitattributes \
  hotdog.env.example \
  docs/README.md \
  docs/status.md \
  docs/mainline-bringup.md \
  docs/boot-flow.md \
  docs/host-setup.md \
  docs/device-safety.md \
  docs/artifacts.md \
  docs/roadmap.md \
  scripts/check-host-tools.sh \
  scripts/env.sh \
  scripts/bootstrap-host.sh \
  scripts/fetch-kexec-tools-aarch64.sh \
  scripts/install-gentoo-qemu-aarch64-user.sh \
  scripts/validate-mainline-go-cycle.sh \
  patches/experimental-android-kernel-header-text-offset.patch \
  pmbootstrap_v3.cfg.example
do
  if [ -e "$ROOT/$path" ]; then
    printf 'OK   %s\n' "$path"
  else
    printf 'MISS %s\n' "$path"
  fi
done
if [ -e "$ROOT/pmbootstrap_v3.cfg" ]; then
  printf 'LOCAL %s\n' "pmbootstrap_v3.cfg"
else
  printf 'MISS  %s\n' "pmbootstrap_v3.cfg (copy from pmbootstrap_v3.cfg.example and adjust paths)"
fi
echo

echo "== workspace size =="
for path in src build downloads experiments images logs pmbootstrap-work reports rootfs tools; do
  if [ -e "$ROOT/$path" ]; then
    du -sh "$ROOT/$path" 2>/dev/null || true
  fi
done | sort -h
echo

case "$mode" in
  --check-host)
    exec "$ROOT/scripts/check-host-tools.sh"
    ;;
  --autopilot)
    exec "$ROOT/scripts/check-host-tools.sh" --autopilot
    ;;
esac

echo "Bootstrap summary complete."
