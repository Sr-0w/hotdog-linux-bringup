#!/usr/bin/env python3
"""Read, and optionally set, a remote subsystem's ETM state over QDSSC.

The sensor DSP exposes Qualcomm's QDSS control service on QRTR, and that is
what `coresight-remote-etm` drives: QMI service 0x33, GET_ETM 0x002b and
SET_ETM 0x002c, addressed by instance rather than node. The driver maps a
remote pid to an instance:

    1 -> 2 modem, 2 -> 5 adsp, 3 -> 8 sensor, 4 -> 3 wlan, 5 -> 13 cdsp

so the SLPI is instance 8. The point of this script is that the service is
already live on a stock kernel — reading the state needs no driver, no device
tree node and no flash.

Usage:
  qdssc-etm.py get [instance]           default instance 8, the sensor DSP
  qdssc-etm.py set <0|1> [instance]     0 disables tracing, 1 enables it

`set` changes remote state and is not a read-only operation.
"""
import ctypes
import ctypes.util
import os
import socket
import struct
import sys

AF_QIPCRTR = 42
QDSSC_SERVICE = 0x33
GET_ETM = 0x002B
SET_ETM = 0x002C
SENSOR_INSTANCE = 8

libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.musl-aarch64.so.1",
                   use_errno=True)


class SockaddrQrtr(ctypes.Structure):
    _fields_ = [("sq_family", ctypes.c_uint16),
                ("sq_node", ctypes.c_uint32),
                ("sq_port", ctypes.c_uint32)]


def fail(what):
    sys.exit("%s: %s" % (what, os.strerror(ctypes.get_errno())))


def lookup(instance):
    """Find the node/port serving QDSSC for this instance, via qrtr-lookup."""
    import subprocess
    try:
        out = subprocess.run(["qrtr-lookup"], capture_output=True, text=True,
                             timeout=10).stdout
    except Exception as exc:
        sys.exit("qrtr-lookup failed: %s" % exc)
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 5 and f[0] == str(QDSSC_SERVICE) and f[2] == str(instance):
            return int(f[3]), int(f[4])
    sys.exit("no QDSSC service for instance %d; is the subsystem up?" % instance)


def qmi_request(msg_id, tlvs=b""):
    """A QMI service request: flags 0, transaction 1, then the TLV block."""
    return struct.pack("<BHHH", 0x00, 1, msg_id, len(tlvs)) + tlvs


def tlv(t, payload):
    return struct.pack("<BH", t, len(payload)) + payload


def parse(reply):
    if len(reply) < 7:
        return None, {}
    _, _, msg_id, length = struct.unpack("<BHHH", reply[:7])
    out, off = {}, 7
    while off + 3 <= 7 + length:
        t, ln = struct.unpack("<BH", reply[off:off + 3])
        out[t] = reply[off + 3:off + 3 + ln]
        off += 3 + ln
    return msg_id, out


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("get", "set"):
        sys.exit(__doc__.strip())

    if args[0] == "get":
        instance = int(args[1]) if len(args) > 1 else SENSOR_INSTANCE
        payload = qmi_request(GET_ETM)
    else:
        if len(args) < 2:
            sys.exit("set needs a state: 0 or 1")
        state = int(args[1])
        instance = int(args[2]) if len(args) > 2 else SENSOR_INSTANCE
        payload = qmi_request(SET_ETM, tlv(0x01, struct.pack("<I", state)))

    node, port = lookup(instance)
    print("QDSSC instance %d at node %d port %d" % (instance, node, port))

    fd = libc.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    if fd < 0:
        fail("socket")

    # bind wants our own node id, which is not knowable in advance, so try
    # candidates with an auto-assigned port -- same approach as ssc-client.py
    for cand in range(0, 12):
        a = SockaddrQrtr(AF_QIPCRTR, cand, 0)
        if libc.bind(fd, ctypes.byref(a), ctypes.sizeof(a)) == 0:
            break
    else:
        fail("bind")

    me = SockaddrQrtr()
    ln = ctypes.c_int(ctypes.sizeof(me))
    libc.getsockname(fd, ctypes.byref(me), ctypes.byref(ln))
    print("bound to node %d port %d" % (me.sq_node, me.sq_port))

    libc.setsockopt(fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                    struct.pack("qq", 5, 0), 16)

    dst = SockaddrQrtr(AF_QIPCRTR, node, port)
    print("-> %s" % payload.hex())
    if libc.sendto(fd, payload, len(payload), 0,
                   ctypes.byref(dst), ctypes.sizeof(dst)) < 0:
        fail("sendto")

    buf = ctypes.create_string_buffer(4096)
    n = libc.recv(fd, buf, 4096, 0)
    if n < 0:
        fail("recv")
    reply = buf.raw[:n]
    print("<- %s" % reply.hex())

    msg_id, tlvs = parse(reply)
    print("reply msg=0x%04x tlvs=%s"
          % (msg_id or 0, {hex(k): v.hex() for k, v in tlvs.items()}))
    if 0x02 in tlvs and len(tlvs[0x02]) >= 4:
        result, error = struct.unpack("<HH", tlvs[0x02][:4])
        print("  result: %s, error %d" % ("ok" if result == 0 else "fail", error))
    for t in (0x10, 0x11):
        if t in tlvs:
            raw = tlvs[t]
            val = struct.unpack("<I", raw[:4])[0] if len(raw) >= 4 else raw[0]
            print("  tlv 0x%02x: %d" % (t, val))


if __name__ == "__main__":
    main()
