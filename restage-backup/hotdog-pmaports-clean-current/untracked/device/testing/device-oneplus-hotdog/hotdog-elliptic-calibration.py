#!/usr/bin/env python3
"""Provision the per-device Elliptic calibration without publishing it."""

import argparse
import os
import pathlib
import subprocess
import tempfile


CALIBRATION_SIZE = 448
PARTITION = pathlib.Path("/dev/disk/by-partlabel/persist")
PERSIST_RELATIVE = pathlib.Path("hotdog/elliptic_calibration_v2.bin")
FIRMWARE = pathlib.Path(
    "/lib/firmware/qcom/sm8150/hotdog/elliptic_calibration_v2.bin"
)


class CalibrationError(RuntimeError):
    pass


def read_calibration(path):
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise CalibrationError(f"cannot read {path}: {exc}") from exc
    if len(data) != CALIBRATION_SIZE:
        raise CalibrationError(
            f"{path}: expected {CALIBRATION_SIZE} bytes, got {len(data)}"
        )
    if not any(data):
        raise CalibrationError(f"{path}: refusing an all-zero calibration")
    return data


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = pathlib.Path(temporary)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def mounted_persist():
    for root in ("/mnt/vendor/persist", "/mnt/persist", "/persist"):
        path = pathlib.Path(root)
        if path.is_mount():
            return path, False
    if not PARTITION.exists():
        raise CalibrationError(f"persist partition is missing: {PARTITION}")
    mountpoint = pathlib.Path(tempfile.mkdtemp(prefix="hotdog-persist-"))
    return mountpoint, True


def mount_partition(mountpoint, writable):
    options = "rw,nosuid,nodev,noexec" if writable else "ro,nosuid,nodev,noexec"
    result = subprocess.run(
        ["mount", "-o", options, os.path.realpath(PARTITION), str(mountpoint)],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise CalibrationError(result.stderr.strip() or "persist mount failed")


def unmount_partition(mountpoint, mounted_here):
    if not mounted_here:
        return
    subprocess.run(["umount", str(mountpoint)], check=False)
    try:
        mountpoint.rmdir()
    except OSError:
        pass


def install_from_persist():
    if FIRMWARE.exists():
        read_calibration(FIRMWARE)
        print(f"Elliptic calibration already installed: {FIRMWARE}")
        return

    mountpoint, mounted_here = mounted_persist()
    try:
        if mounted_here:
            mount_partition(mountpoint, writable=False)
        source = mountpoint / PERSIST_RELATIVE
        data = read_calibration(source)
        write_atomic(FIRMWARE, data)
        print(f"Elliptic calibration provisioned from persist: {FIRMWARE}")
    finally:
        unmount_partition(mountpoint, mounted_here)


def store_in_persist(source):
    data = read_calibration(source)
    mountpoint, mounted_here = mounted_persist()
    try:
        if mounted_here:
            mount_partition(mountpoint, writable=True)
        destination = mountpoint / PERSIST_RELATIVE
        write_atomic(destination, data)
        if read_calibration(destination) != data:
            raise CalibrationError("persist calibration readback mismatch")
        print(f"Elliptic calibration stored for future images: {destination}")
    finally:
        unmount_partition(mountpoint, mounted_here)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--store",
        type=pathlib.Path,
        metavar="CALIBRATION",
        help="validate and store a per-device calibration in persist",
    )
    args = parser.parse_args()
    try:
        if args.store:
            store_in_persist(args.store)
        else:
            install_from_persist()
    except CalibrationError as exc:
        parser.exit(1, f"hotdog Elliptic calibration: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
