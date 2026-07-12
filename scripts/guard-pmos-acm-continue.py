#!/usr/bin/env python3
"""Prearm a bootloader fallback before leaving the pmOS USB ACM shell."""

import argparse
import base64
import hashlib
import os
import select
import sys
import termios
import time


PROMPT = b"~ #"
EXPECTED_BANNER = b"hotdog initramfs USB ACM shell"
REMOTE_HELPER = "/tmp/hotdog-reboot-mode"


def read_until(fd, marker, timeout):
    deadline = time.monotonic() + timeout
    output = bytearray()
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.25)
        if not readable:
            continue
        try:
            chunk = os.read(fd, 262144)
        except BlockingIOError:
            continue
        if not chunk:
            continue
        output.extend(chunk)
        if marker in output:
            return bytes(output)
    raise TimeoutError(f"timed out waiting for {marker!r}")


def write_line(fd, value):
    os.write(fd, value.encode("ascii") + b"\r\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="/dev/ttyACM0")
    parser.add_argument("--helper", required=True)
    parser.add_argument("--helper-sha256", required=True)
    parser.add_argument("--fallback-delay", type=int, default=180)
    parser.add_argument("--log-delay", type=int, default=45)
    parser.add_argument("--prompt-timeout", type=int, default=20)
    parser.add_argument("--boot-uuid", default="9ecffd22-eacf-4b9f-9b0f-3f7ca738a731")
    parser.add_argument("--root-uuid", default="de13a416-8942-4d87-9947-dce62fba9465")
    args = parser.parse_args()

    helper = open(args.helper, "rb").read()
    actual_sha = hashlib.sha256(helper).hexdigest()
    if actual_sha != args.helper_sha256:
        raise RuntimeError(
            f"helper SHA256 mismatch: expected {args.helper_sha256}, got {actual_sha}"
        )
    if not 30 <= args.fallback_delay <= 900:
        raise RuntimeError("fallback delay must be between 30 and 900 seconds")
    if not 5 <= args.log_delay < args.fallback_delay:
        raise RuntimeError("log delay must be at least 5s and below fallback delay")

    fd = os.open(args.device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        attrs = termios.tcgetattr(fd)
        attrs[3] &= ~(termios.ECHO | termios.ICANON)
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        os.write(fd, b"\r\n")
        banner = read_until(fd, PROMPT, args.prompt_timeout)
        if EXPECTED_BANNER not in banner:
            raise RuntimeError("refusing non-hotdog or non-initramfs ACM endpoint")

        write_line(
            fd,
            "/bin/busybox ash /hooks/00-hotdog-super-loop-fix.sh; "
            "echo ACM_STORAGE_CHECK; blkid",
        )
        storage = read_until(fd, PROMPT, 30)
        for label, uuid in (
            ("pmOS_boot", args.boot_uuid),
            ("pmOS_root", args.root_uuid),
        ):
            if label.encode("ascii") not in storage or uuid.encode("ascii") not in storage:
                raise RuntimeError(f"{label} with UUID {uuid} was not exposed")

        write_line(fd, f"rm -f {REMOTE_HELPER}.b64 {REMOTE_HELPER}")
        read_until(fd, PROMPT, 5)
        payload = base64.b64encode(helper).decode("ascii")
        for offset in range(0, len(payload), 512):
            chunk = payload[offset : offset + 512]
            write_line(fd, f"printf '%s' '{chunk}' >> {REMOTE_HELPER}.b64")
            read_until(fd, PROMPT, 5)
        write_line(
            fd,
            f"base64 -d {REMOTE_HELPER}.b64 > {REMOTE_HELPER}; "
            f"chmod 700 {REMOTE_HELPER}; sha256sum {REMOTE_HELPER}",
        )
        verification = read_until(fd, PROMPT, 10)
        if args.helper_sha256.encode("ascii") not in verification:
            raise RuntimeError("remote helper SHA256 verification failed")

        watchdog = (
            f"nohup sh -c 'sleep {args.log_delay}; "
            "echo ACM_GUARD_LOG_BEGIN > /dev/ttyGS0; "
            "cat /pmOS_init.log > /dev/ttyGS0 2>&1; "
            "echo ACM_GUARD_LOG_END > /dev/ttyGS0; "
            f"sleep {args.fallback_delay - args.log_delay}; "
            f"{REMOTE_HELPER} bootloader' </dev/null >/dev/ttyGS0 2>&1 &"
        )
        write_line(fd, watchdog)
        armed = read_until(fd, PROMPT, 10)
        if b"not found" in armed or b"ERROR" in armed:
            raise RuntimeError("ACM fallback command was not armed")

        write_line(fd, "echo ACM_GUARD_ARMED; pmos_continue_boot")
        output = read_until(fd, b"Continuing boot", 20)
        sys.stdout.buffer.write(banner)
        sys.stdout.buffer.write(storage)
        sys.stdout.buffer.write(verification)
        sys.stdout.buffer.write(armed)
        sys.stdout.buffer.write(output)
        print(
            f"\nACM fallback armed for {args.fallback_delay}s and boot continuation dispatched"
        )
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, TimeoutError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
