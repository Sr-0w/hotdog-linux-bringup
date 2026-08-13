#!/usr/bin/env python3
"""Talk to the Snapdragon Sensor Core service on QRTR.

The sensor core publishes QMI service 400. Its messages carry protobuf
payloads rather than ordinary QMI TLV structures, so this speaks both layers:
a QMI envelope around a `sns_client_request_msg`.

Discovery works by asking a well-known sensor, the SUID lookup, for the
identifiers of sensors providing a named data type. Those identifiers are then
what a real client subscribes to.

Usage: ssc-client.py [data-type]        default: accel
"""
import ctypes, ctypes.util, os, socket, struct, sys, time

AF_QIPCRTR = 42
SSC_SERVICE = 400

# QMI message ids for the sensor client service
SNS_CLIENT_REQ = 0x0020
SNS_CLIENT_IND = 0x0021

# The SUID of the lookup sensor is fixed and known; every other identifier is
# discovered through it.
SUID_LOOKUP = (0xABABABABABABABAB, 0xABABABABABABABAB)

libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.musl-aarch64.so.1",
                   use_errno=True)


class SockaddrQrtr(ctypes.Structure):
    _fields_ = [("sq_family", ctypes.c_uint16),
                ("sq_node", ctypes.c_uint32),
                ("sq_port", ctypes.c_uint32)]


def fail(what):
    sys.exit("%s: %s" % (what, os.strerror(ctypes.get_errno())))


# ---------------------------------------------------------------- protobuf

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field(num, wire, payload):
    return varint(num << 3 | wire) + payload


def pb_bytes(num, raw):
    return field(num, 2, varint(len(raw)) + raw)


def pb_uint(num, value):
    return field(num, 0, varint(value))


def pb_fixed64(num, value):
    return field(num, 1, struct.pack("<Q", value))


def suid_msg(low, high):
    return pb_fixed64(1, low) + pb_fixed64(2, high)


def parse(raw):
    """Walk a protobuf message into {field: [values]}, values kept raw."""
    out, i = {}, 0
    while i < len(raw):
        key, i = read_varint(raw, i)
        num, wire = key >> 3, key & 7
        if wire == 0:
            val, i = read_varint(raw, i)
        elif wire == 1:
            val, i = struct.unpack_from("<Q", raw, i)[0], i + 8
        elif wire == 2:
            ln, i = read_varint(raw, i)
            val, i = raw[i:i + ln], i + ln
        elif wire == 5:
            val, i = struct.unpack_from("<I", raw, i)[0], i + 4
        else:
            break
        out.setdefault(num, []).append(val)
    return out


def read_varint(raw, i):
    shift = res = 0
    while i < len(raw):
        b = raw[i]
        i += 1
        res |= (b & 0x7f) << shift
        if not b & 0x80:
            return res, i
        shift += 7
    return res, i


# -------------------------------------------------------------------- qmi

def qmi_request(txn, msg_id, payload):
    # The payload is a variable-length array in the QMI definition, so the
    # TLV value carries its own uint16 count before the bytes. Without that
    # the service reads the head of the protobuf as a length and rejects the
    # message as too long.
    value = struct.pack("<H", len(payload)) + payload
    tlv = b"\x01" + struct.pack("<H", len(value)) + value
    return struct.pack("<BHHH", 0, txn, msg_id, len(tlv)) + tlv


def qmi_split(buf):
    if len(buf) < 7:
        return None
    _type, txn, msg_id, length = struct.unpack_from("<BHHH", buf, 0)
    body, out, i = buf[7:7 + length], {}, 0
    while i + 3 <= len(body):
        t = body[i]
        ln = struct.unpack_from("<H", body, i + 1)[0]
        out[t] = body[i + 3:i + 3 + ln]
        i += 3 + ln
    return txn, msg_id, out


# ------------------------------------------------------------------- main

def find_service():
    """Read the service list and return (node, port) for the sensor core."""
    import subprocess
    try:
        listing = subprocess.run(["qrtr-lookup"], capture_output=True,
                                 text=True, timeout=20).stdout
    except Exception as e:
        sys.exit("qrtr-lookup: %s" % e)
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0] == str(SSC_SERVICE):
            return int(parts[3]), int(parts[4])
    sys.exit("service %d is not registered" % SSC_SERVICE)


def main():
    want = (sys.argv[1] if len(sys.argv) > 1 else "accel").encode()
    node, port = find_service()
    print("sensor core at node %d port %d" % (node, port))

    fd = libc.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    if fd < 0:
        fail("socket")

    # bind wants our own node id, which is not knowable in advance
    for cand in range(0, 12):
        a = SockaddrQrtr(AF_QIPCRTR, cand, 0)
        if libc.bind(fd, ctypes.byref(a), ctypes.sizeof(a)) == 0:
            local = cand
            break
    else:
        fail("bind")

    me = SockaddrQrtr()
    ln = ctypes.c_int(ctypes.sizeof(me))
    libc.getsockname(fd, ctypes.byref(me), ctypes.byref(ln))
    print("bound to node %d port %d" % (me.sq_node, me.sq_port))

    # sns_suid_req { data_type = <name>, register_updates = false }
    suid_req = pb_bytes(1, want) + pb_uint(2, 1)

    # sns_std_suspend_config { client_proc_type = APSS, delivery_type = WAKEUP }
    # APSS is 0 in the enum; 1 is the SSC itself, which would have the answer
    # delivered to the DSP rather than to us.
    susp = pb_uint(1, 0) + pb_uint(2, 0)

    # sns_std_request { susp_config, payload }
    std_req = pb_bytes(1, susp) + pb_bytes(2, suid_req)

    # sns_client_request_msg { suid, msg_id, request }
    body = (pb_bytes(1, suid_msg(*SUID_LOOKUP))
            + pb_uint(2, 512)                       # SNS_SUID_MSGID_SNS_SUID_REQ
            + pb_bytes(3, std_req))

    pkt = qmi_request(1, SNS_CLIENT_REQ, body)
    dst = SockaddrQrtr(AF_QIPCRTR, node, port)
    buf = ctypes.create_string_buffer(pkt)
    if libc.sendto(fd, buf, len(pkt), 0, ctypes.byref(dst),
                   ctypes.sizeof(dst)) < 0:
        fail("sendto")
    print("sent %d bytes asking for '%s'" % (len(pkt), want.decode()))

    libc.setsockopt(fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                    struct.pack("qq", 1, 0), 16)

    rx = ctypes.create_string_buffer(65536)
    end = time.time() + 25
    while time.time() < end:
        n = libc.recvfrom(fd, rx, 65536, 0, None, None)
        if n <= 0:
            # a receive timeout is not the end: the reply is immediate but the
            # indication carrying the answer arrives later
            continue
        raw = rx.raw[:n]
        split = qmi_split(raw)
        if split is None:
            print("short packet: %s" % raw.hex())
            continue
        txn, msg_id, tlvs = split
        print("reply txn=%d msg=0x%04x tlvs=%s"
              % (txn, msg_id, {k: len(v) for k, v in tlvs.items()}))
        for t, v in tlvs.items():
            if t == 0x02 and len(v) >= 4:
                res, err = struct.unpack_from("<HH", v, 0)
                print("  result: %s, error %d" % ("ok" if res == 0 else "failure", err))
            elif t in (0x10, 0x11):
                print("  tlv 0x%02x: %s" % (t, v.hex()))
            elif t == 0x01:
                fields = parse(v)
                print("  payload fields: %s" % sorted(fields))
                for suid in fields.get(1, []):
                    if isinstance(suid, bytes):
                        s = parse(suid)
                        if 1 in s and 2 in s:
                            print("  SUID %016x%016x" % (s[2][0], s[1][0]))
    print("done")


if __name__ == "__main__":
    main()
