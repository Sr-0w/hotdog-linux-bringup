#!/usr/bin/env python3
"""Subscribe to a Snapdragon Sensor Core SUID over QRTR.

The SUID is printed by ``ssc-client.py`` as 32 hexadecimal digits.  Physical
on-change sensors use the standard empty ``SNS_STD_ON_CHANGE_CONFIG`` request.
This helper deliberately leaves sensor-specific payloads undecoded while
printing their message id, timestamp and protobuf fields verbatim.

Usage: ssc-subscribe.py SUID [SECONDS]
"""
import ctypes
import importlib.util
import pathlib
import socket
import struct
import sys
import time


HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("ssc_client", HERE / "ssc-client.py")
SSC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SSC)

SNS_STD_ON_CHANGE_CONFIG = 514
SNS_STD_SENSOR_CONFIG_EVENT = 768
SNS_STD_SENSOR_EVENT = 769


def decode_suid(text):
    if len(text) != 32:
        raise ValueError("SUID must contain exactly 32 hexadecimal digits")
    high = int(text[:16], 16)
    low = int(text[16:], 16)
    return low, high


def describe(value):
    if isinstance(value, bytes):
        return value.hex()
    return str(value)


def describe_sensor_event(message_id, payload):
    """Decode the common sensor event without guessing vendor payloads."""
    if message_id != SNS_STD_SENSOR_EVENT:
        return None

    fields = SSC.parse(payload)
    packed = fields.get(1, [None])[0]
    if not isinstance(packed, bytes) or len(packed) % 4:
        return None

    samples = struct.unpack("<%df" % (len(packed) // 4), packed)
    status = fields.get(2, [None])[0]
    return "samples=%s status=%s" % (
        ",".join("%.6g" % value for value in samples), status)


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: ssc-subscribe.py SUID [SECONDS]")

    low, high = decode_suid(sys.argv[1])
    duration = float(sys.argv[2]) if len(sys.argv) == 3 else 20.0
    if duration <= 0:
        sys.exit("SECONDS must be greater than zero")
    node, port = SSC.find_service()

    fd = SSC.libc.socket(SSC.AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    if fd < 0:
        SSC.fail("socket")

    for candidate in range(12):
        address = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, candidate, 0)
        if SSC.libc.bind(fd, ctypes.byref(address), ctypes.sizeof(address)) == 0:
            break
    else:
        SSC.fail("bind")

    config = SSC.pb_uint(1, 1) + SSC.pb_uint(2, 0)
    request = SSC.pb_bytes(2, b"")
    body = (SSC.pb_bytes(1, SSC.suid_msg(low, high))
            + SSC.field(2, 5, struct.pack("<I", SNS_STD_ON_CHANGE_CONFIG))
            + SSC.pb_bytes(3, config)
            + SSC.pb_bytes(4, request))
    packet = SSC.qmi_request(1, SSC.SNS_CLIENT_REQ, body)
    destination = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, node, port)
    buffer = ctypes.create_string_buffer(packet)
    if SSC.libc.sendto(fd, buffer, len(packet), 0,
                       ctypes.byref(destination), ctypes.sizeof(destination)) < 0:
        SSC.fail("sendto")

    print("subscribed to %016x%016x at node %d port %d for %.1f seconds"
          % (high, low, node, port, duration))
    SSC.libc.setsockopt(fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                        struct.pack("qq", 1, 0), 16)

    receive = ctypes.create_string_buffer(65536)
    deadline = time.time() + duration
    while time.time() < deadline:
        size = SSC.libc.recvfrom(fd, receive, len(receive), 0, None, None)
        if size <= 0:
            continue
        raw = receive.raw[:size]
        split = SSC.qmi_split(raw)
        if split is None:
            print("short packet: %s" % raw.hex())
            continue
        txn, message_id, tlvs = split
        print("qmi txn=%d msg=0x%04x tlvs=%s"
              % (txn, message_id, {key: len(value) for key, value in tlvs.items()}))
        indication = tlvs.get(2)
        if message_id not in (SSC.SNS_CLIENT_IND_SMALL, SSC.SNS_CLIENT_IND_LARGE):
            if indication is not None and len(indication) >= 4:
                result, error = struct.unpack_from("<HH", indication)
                print("  result=%d error=%d" % (result, error))
            continue
        if indication is None or len(indication) < 2:
            continue

        count = struct.unpack_from("<H", indication)[0]
        envelope = SSC.parse(indication[2:2 + count])
        # sns_client_event_msg field 1 is the source SUID. Only field 2
        # contains repeated sns_client_event entries.
        for event_raw in envelope.get(2, []):
            if not isinstance(event_raw, bytes):
                continue
            event = SSC.parse(event_raw)
            message_id = event.get(1, [None])[0]
            timestamp = event.get(2, [None])[0]
            payload = event.get(3, [b""])[0]
            name = {
                SNS_STD_SENSOR_CONFIG_EVENT: "config",
                SNS_STD_SENSOR_EVENT: "sensor",
            }.get(message_id, "unknown")
            fields = {key: [describe(item) for item in values]
                      for key, values in event.items()}
            print("  event id=%s (%s) timestamp=%s fields=%s"
                  % (message_id, name, timestamp, fields))
            if isinstance(payload, bytes):
                decoded = describe_sensor_event(message_id, payload)
                if decoded is not None:
                    print("    %s" % decoded)


if __name__ == "__main__":
    main()
