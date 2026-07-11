#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/env.sh"

env_source="$HOTDOG_ROOT/host/portage/env/qemu-aarch64-user.conf"
package_env_source="$HOTDOG_ROOT/host/portage/package.env/qemu-aarch64-user"

[ -r /etc/gentoo-release ] || {
  echo "This installer is only for Gentoo hosts" >&2
  exit 2
}
[ -s "$env_source" ] || {
  echo "Missing Portage env template: $env_source" >&2
  exit 2
}
[ -s "$package_env_source" ] || {
  echo "Missing Portage package.env template: $package_env_source" >&2
  exit 2
}
command -v sudo >/dev/null 2>&1 || {
  echo "Missing sudo" >&2
  exit 127
}
command -v emerge >/dev/null 2>&1 || {
  echo "Missing emerge" >&2
  exit 127
}

sudo install -d -m 0755 /etc/portage/env /etc/portage/package.env
sudo install -m 0644 "$env_source" /etc/portage/env/qemu-aarch64-user.conf
sudo install -m 0644 "$package_env_source" /etc/portage/package.env/qemu-aarch64-user
sudo emerge --ask=n --oneshot app-emulation/qemu

command -v qemu-aarch64 >/dev/null 2>&1 || {
  echo "qemu-aarch64 was not installed" >&2
  exit 1
}
qemu-aarch64 --version | sed -n '1p'
