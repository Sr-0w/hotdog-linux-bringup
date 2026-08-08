#!/usr/bin/env python3
"""Capture V4L2 multiplanar buffers after pre-filling them with a byte."""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import hashlib
import mmap
import os
import select
import sys
import time


VIDIOC_REQBUFS = 0xC0145608
VIDIOC_QUERYBUF = 0xC0585609
VIDIOC_QBUF = 0xC058560F
VIDIOC_DQBUF = 0xC0585611
VIDIOC_STREAMON = 0x40045612
VIDIOC_STREAMOFF = 0x40045613

V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE = 9
V4L2_MEMORY_MMAP = 1


class V4L2PlaneMemory(ctypes.Union):
    _fields_ = [
        ("mem_offset", ctypes.c_uint32),
        ("userptr", ctypes.c_ulong),
        ("fd", ctypes.c_int32),
    ]


class V4L2Plane(ctypes.Structure):
    _fields_ = [
        ("bytesused", ctypes.c_uint32),
        ("length", ctypes.c_uint32),
        ("m", V4L2PlaneMemory),
        ("data_offset", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32 * 11),
    ]


class Timeval(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_usec", ctypes.c_long)]


class V4L2Timecode(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("frames", ctypes.c_uint8),
        ("seconds", ctypes.c_uint8),
        ("minutes", ctypes.c_uint8),
        ("hours", ctypes.c_uint8),
        ("userbits", ctypes.c_uint8 * 4),
    ]


class V4L2BufferMemory(ctypes.Union):
    _fields_ = [
        ("offset", ctypes.c_uint32),
        ("userptr", ctypes.c_ulong),
        ("planes", ctypes.POINTER(V4L2Plane)),
        ("fd", ctypes.c_int32),
    ]


class V4L2BufferRequest(ctypes.Union):
    _fields_ = [("request_fd", ctypes.c_int32), ("reserved", ctypes.c_uint32)]


class V4L2Buffer(ctypes.Structure):
    _fields_ = [
        ("index", ctypes.c_uint32),
        ("type", ctypes.c_uint32),
        ("bytesused", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("field", ctypes.c_uint32),
        ("timestamp", Timeval),
        ("timecode", V4L2Timecode),
        ("sequence", ctypes.c_uint32),
        ("memory", ctypes.c_uint32),
        ("m", V4L2BufferMemory),
        ("length", ctypes.c_uint32),
        ("reserved2", ctypes.c_uint32),
        ("request", V4L2BufferRequest),
    ]


def parse_byte(value: str) -> int:
    parsed = int(value, 0)
    if not 0 <= parsed <= 0xFF:
        raise argparse.ArgumentTypeError("fill byte must be between 0 and 255")
    return parsed


def new_buffer(index: int = 0) -> tuple[V4L2Buffer, ctypes.Array[V4L2Plane]]:
    planes = (V4L2Plane * 1)()
    buffer = V4L2Buffer()
    buffer.index = index
    buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
    buffer.memory = V4L2_MEMORY_MMAP
    buffer.m.planes = ctypes.cast(planes, ctypes.POINTER(V4L2Plane))
    buffer.length = 1
    return buffer, planes


def ioctl(fd: int, request: int, argument: object) -> None:
    fcntl.ioctl(fd, request, argument)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="/dev/video0")
    parser.add_argument("--buffers", type=int, default=2)
    parser.add_argument("--frames", type=int, default=3)
    parser.add_argument("--poll-timeout-ms", type=int, default=8000)
    parser.add_argument("--hold-after-streamon-ms", type=int, default=0)
    parser.add_argument("--fill", type=parse_byte, default=0xAA)
    parser.add_argument("--dump-first")
    args = parser.parse_args()

    if args.buffers < 1 or args.frames < 1 or args.poll_timeout_ms < 1:
        parser.error("buffers, frames and poll timeout must be positive")
    if args.hold_after_streamon_ms < 0:
        parser.error("hold after streamon must not be negative")

    fd = os.open(args.device, os.O_RDWR | os.O_NONBLOCK)
    mappings: list[mmap.mmap] = []
    streaming = False
    captured = 0
    changed_any = False

    try:
        # v4l2_requestbuffers: four u32s, one u8 flag, three reserved bytes.
        request_buffers = bytearray(20)
        ctypes.c_uint32.from_buffer(request_buffers, 0).value = args.buffers
        ctypes.c_uint32.from_buffer(request_buffers, 4).value = (
            V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
        )
        ctypes.c_uint32.from_buffer(request_buffers, 8).value = V4L2_MEMORY_MMAP
        ioctl(fd, VIDIOC_REQBUFS, request_buffers)
        allocated = ctypes.c_uint32.from_buffer(request_buffers, 0).value
        if allocated < 1:
            raise RuntimeError("driver allocated no capture buffers")
        print(f"BUFFERS requested={args.buffers} allocated={allocated}", flush=True)

        fill_block = bytes([args.fill])
        for index in range(allocated):
            buffer, planes = new_buffer(index)
            ioctl(fd, VIDIOC_QUERYBUF, buffer)
            length = planes[0].length
            mapping = mmap.mmap(
                fd,
                length,
                flags=mmap.MAP_SHARED,
                prot=mmap.PROT_READ | mmap.PROT_WRITE,
                offset=planes[0].m.mem_offset,
            )
            mapping[:] = fill_block * length
            mappings.append(mapping)
            print(
                f"PREFILL index={index} length={length} byte=0x{args.fill:02x}",
                flush=True,
            )
            ioctl(fd, VIDIOC_QBUF, buffer)

        buffer_type = ctypes.c_int(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
        ioctl(fd, VIDIOC_STREAMON, buffer_type)
        streaming = True
        print("STREAM state=on", flush=True)
        if args.hold_after_streamon_ms:
            print(
                f"HOLD after_streamon_ms={args.hold_after_streamon_ms}",
                flush=True,
            )
            time.sleep(args.hold_after_streamon_ms / 1000)

        poller = select.poll()
        poller.register(fd, select.POLLIN | select.POLLPRI | select.POLLERR)

        while captured < args.frames:
            events = poller.poll(args.poll_timeout_ms)
            if not events:
                print(
                    f"TIMEOUT after_ms={args.poll_timeout_ms} frames={captured}",
                    flush=True,
                )
                return 4

            buffer, planes = new_buffer()
            try:
                ioctl(fd, VIDIOC_DQBUF, buffer)
            except BlockingIOError as exc:
                if exc.errno == errno.EAGAIN:
                    print("POLL spurious=1", flush=True)
                    continue
                raise

            data = mappings[buffer.index][:]
            fill_count = data.count(args.fill)
            zero_count = data.count(0)
            changed = len(data) - fill_count
            changed_any |= changed > 0
            digest = hashlib.sha256(data).hexdigest()
            print(
                "FRAME "
                f"number={captured} sequence={buffer.sequence} index={buffer.index} "
                f"length={len(data)} bytesused={planes[0].bytesused} "
                f"fill_count={fill_count} zero_count={zero_count} "
                f"changed={changed} sha256={digest}",
                flush=True,
            )

            if captured == 0 and args.dump_first:
                with open(args.dump_first, "wb") as output:
                    output.write(data)
                print(f"DUMP_FIRST path={args.dump_first}", flush=True)

            captured += 1
            ioctl(fd, VIDIOC_QBUF, buffer)

        print(
            f"SUMMARY frames={captured} changed_any={int(changed_any)} "
            f"fill=0x{args.fill:02x}",
            flush=True,
        )
        return 0
    finally:
        if streaming:
            try:
                buffer_type = ctypes.c_int(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
                ioctl(fd, VIDIOC_STREAMOFF, buffer_type)
                print("STREAM state=off", flush=True)
            except OSError as exc:
                print(f"STREAMOFF error={exc}", file=sys.stderr, flush=True)
        for mapping in mappings:
            mapping.close()
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
