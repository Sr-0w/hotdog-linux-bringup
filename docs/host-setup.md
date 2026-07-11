# Host setup

The tooling was developed on Gentoo Linux, but most scripts use standard Linux
utilities and can be adapted to other distributions.

## Required tools

Core requirements include:

- Bash, Git, GNU coreutils, findutils, grep, sed, and awk
- `cpio`, `gzip`, `file`, `sha256sum`, and `readelf`
- Device Tree Compiler tools such as `dtc`, `fdtdump`, `fdtget`, and `fdtput`
- Android platform tools with `adb`, `fastboot`, `mkbootimg`, and
  `unpack_bootimg`
- Python 3 and postmarketOS `pmbootstrap`
- OpenSSH, `sshpass`, and `socat` or `telnet` for diagnostic channels
- QEMU user-mode AArch64 support for offline helper validation
- ShellCheck for script validation

Run the repository check to identify missing commands:

```bash
./scripts/check-host-tools.sh
```

## Source bootstrap

```bash
./scripts/bootstrap-sources.sh --kernel-mainline
```

This populates the ignored `src/` directory. Add `--linux-next` only when
linux-next comparison is required; it is not needed for the validated cycle.

## pmbootstrap configuration

Create a machine-local configuration:

```bash
cp pmbootstrap_v3.cfg.example pmbootstrap_v3.cfg
```

Review at least:

- the `aports` path
- the work directory
- job count and ccache size
- locale and timezone

The example intentionally uses repository-relative paths and is safe to adapt.
The real `pmbootstrap_v3.cfg` is ignored.

Create a local device configuration before running SSH or fastboot helpers:

```bash
cp hotdog.env.example hotdog.env
```

Set the device serial and postmarketOS password in `hotdog.env`. The real file
is ignored and loaded automatically by `scripts/env.sh`.

## Gentoo notes

The repository contains optional Gentoo snippets under `host/portage/`. They
are examples, not files to copy blindly into `/etc/portage`.

On Gentoo, `dev-util/android-tools` must expose the Android image utilities.
QEMU AArch64 user support can be prepared with:

```bash
./scripts/install-gentoo-qemu-aarch64-user.sh
```

## Host USB network

The validated USB gadget uses:

```text
phone: 172.16.42.1/24
host:  172.16.42.2/24
```

An example udev rule is provided at `host/udev/53-hotdog-pmos-gadget.rules`.
Review interface names and NetworkManager behavior before installing it.

## Validation before hardware use

```bash
./scripts/bootstrap-host.sh --check-host
./scripts/validate-mainline-go-cycle.sh
```

Both commands are offline checks and should complete before a phone operation
is attempted.
