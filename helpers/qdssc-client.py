#!/usr/bin/env python3
"""Inspect or configure Qualcomm Debug Subsystem Control over QRTR.

The SLPI firmware exposes QDSSC (QMI service 51) once for the sensor root PD
and once for the sensor user PD.  This helper intentionally defaults to
read-only queries.  Pass ``--enable`` only when a trace sink has been prepared.
"""

import argparse
import ctypes
import ctypes.util
import os
import socket
import struct
import subprocess
import sys


AF_QIPCRTR = 42
QDSSC_SERVICE = 51
QMI_GET_SWT = 0x0020
QMI_SET_SWT = 0x0021
QMI_GET_ENTITY = 0x0022
QMI_SET_ENTITY = 0x0023

ENTITIES = {
    "tds": 1,
    "ulog": 11,
    "prof": 12,
    "diag": 13,
}

libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.musl-aarch64.so.1",
                   use_errno=True)


class SockaddrQrtr(ctypes.Structure):
    _fields_ = [("sq_family", ctypes.c_uint16),
                ("sq_node", ctypes.c_uint32),
                ("sq_port", ctypes.c_uint32)]


def fail(what):
    raise OSError(ctypes.get_errno(), "%s: %s" %
                  (what, os.strerror(ctypes.get_errno())))


def endpoints():
    listing = subprocess.run(["qrtr-lookup"], capture_output=True, text=True,
                             timeout=20, check=True).stdout
    found = []
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) >= 5 and fields[0] == str(QDSSC_SERVICE):
            found.append(tuple(map(int, fields[:5])))
    return found


def qmi_request(txn, msg_id, tlvs=b""):
    return struct.pack("<BHHH", 0, txn, msg_id, len(tlvs)) + tlvs


def tlv(number, payload):
    return struct.pack("<BH", number, len(payload)) + payload


def split_qmi(buf):
    if len(buf) < 7:
        return None
    msg_type, txn, msg_id, length = struct.unpack_from("<BHHH", buf)
    body = buf[7:7 + length]
    values = {}
    offset = 0
    while offset + 3 <= len(body):
        number, size = struct.unpack_from("<BH", body, offset)
        offset += 3
        values[number] = body[offset:offset + size]
        offset += size
    return msg_type, txn, msg_id, values


def transact(fd, node, port, txn, msg_id, tlvs=b""):
    packet = qmi_request(txn, msg_id, tlvs)
    destination = SockaddrQrtr(AF_QIPCRTR, node, port)
    buf = ctypes.create_string_buffer(packet)
    if libc.sendto(fd, buf, len(packet), 0, ctypes.byref(destination),
                   ctypes.sizeof(destination)) < 0:
        fail("sendto")

    rx = ctypes.create_string_buffer(4096)
    n = libc.recvfrom(fd, rx, len(rx), 0, None, None)
    if n < 0:
        fail("recvfrom")
    decoded = split_qmi(rx.raw[:n])
    if decoded is None:
        raise RuntimeError("short QMI response")
    _, response_txn, response_id, response_tlvs = decoded
    if response_txn != txn or response_id != msg_id:
        raise RuntimeError("unexpected QMI response")
    result = response_tlvs.get(2, b"")
    if len(result) >= 4:
        status, error = struct.unpack_from("<HH", result)
        if status:
            raise RuntimeError("QMI request failed: error %d" % error)
    return response_tlvs


def state_from_response(response):
    value = response.get(0x10)
    if value is None or len(value) < 4:
        return "not returned"
    return "enabled" if struct.unpack_from("<I", value)[0] else "disabled"


def inspect_endpoint(fd, node, port, instance, enable):
    print("instance=%d node=%d port=%d" % (instance, node, port))
    txn = 1
    if enable:
        transact(fd, node, port, txn, QMI_SET_SWT,
                 tlv(1, struct.pack("<I", 1)))
        txn += 1
    response = transact(fd, node, port, txn, QMI_GET_SWT)
    print("  software trace: %s" % state_from_response(response))
    txn += 1

    for name, entity in ENTITIES.items():
        if enable:
            payload = tlv(1, struct.pack("<I", entity))
            payload += tlv(2, struct.pack("<I", 1))
            try:
                transact(fd, node, port, txn, QMI_SET_ENTITY, payload)
            except RuntimeError as error:
                print("  %-5s enable: %s" % (name, error))
            txn += 1
        response = transact(fd, node, port, txn, QMI_GET_ENTITY,
                            tlv(1, struct.pack("<I", entity)))
        print("  %-5s: %s" % (name, state_from_response(response)))
        txn += 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--enable", action="store_true",
                        help="enable software, ULog, and DIAG tracing")
    parser.add_argument("--instance", type=int, action="append",
                        help="limit the operation to a QDSSC instance")
    args = parser.parse_args()

    found = endpoints()
    if not found:
        sys.exit("QDSSC service is not registered")

    fd = libc.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    if fd < 0:
        fail("socket")
    for candidate in range(12):
        address = SockaddrQrtr(AF_QIPCRTR, candidate, 0)
        if libc.bind(fd, ctypes.byref(address), ctypes.sizeof(address)) == 0:
            break
    else:
        fail("bind")
    libc.setsockopt(fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                    struct.pack("qq", 2, 0), 16)

    for service, version, instance, node, port in found:
        if args.instance and instance not in args.instance:
            continue
        try:
            inspect_endpoint(fd, node, port, instance, args.enable)
        except Exception as error:
            print("instance=%d node=%d port=%d: %s" %
                  (instance, node, port, error), file=sys.stderr)


if __name__ == "__main__":
    main()
