#!/usr/bin/env python3
"""List services on the QRTR bus.

Python knows AF_QIPCRTR but not how to marshal its addresses, so the socket
calls go through ctypes with a hand-built sockaddr_qrtr.
"""
import ctypes, ctypes.util, socket, struct, sys, time

AF_QIPCRTR = 42
CTRL_PORT  = 0xfffffffe
NEW_SERVER, NEW_LOOKUP = 2, 7

libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.musl-aarch64.so.1", use_errno=True)

class SockaddrQrtr(ctypes.Structure):
    _fields_ = [("sq_family", ctypes.c_uint16),
                ("sq_node",   ctypes.c_uint32),
                ("sq_port",   ctypes.c_uint32)]

def die(what):
    e = ctypes.get_errno()
    print("%s failed: %s" % (what, __import__("os").strerror(e)))
    sys.exit(1)

fd = libc.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
if fd < 0:
    die("socket")

local = None
for cand in range(0, 12):
    a = SockaddrQrtr(AF_QIPCRTR, cand, 0)
    if libc.bind(fd, ctypes.byref(a), ctypes.sizeof(a)) == 0:
        local = cand
        break
if local is None:
    die("bind")
print("noeud local: %d" % local)
addr = SockaddrQrtr(AF_QIPCRTR, local, 0)

me = SockaddrQrtr()
ln = ctypes.c_int(ctypes.sizeof(me))
libc.getsockname(fd, ctypes.byref(me), ctypes.byref(ln))
print("local node %d port %d" % (me.sq_node, me.sq_port))

pkt = struct.pack("<5I", NEW_LOOKUP, 0, 0, 0, 0)
dst = SockaddrQrtr(AF_QIPCRTR, me.sq_node, CTRL_PORT)
buf = ctypes.create_string_buffer(pkt)
if libc.sendto(fd, buf, len(pkt), 0, ctypes.byref(dst), ctypes.sizeof(dst)) < 0:
    die("sendto")

tv = struct.pack("qq", 3, 0)
libc.setsockopt(fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO, tv, len(tv))

seen, rx = set(), ctypes.create_string_buffer(256)
end = time.time() + 5
while time.time() < end:
    n = libc.recvfrom(fd, rx, 256, 0, None, None)
    if n < 20:
        break
    cmd, service, instance, node, port = struct.unpack_from("<5I", rx.raw)
    if cmd != NEW_SERVER:
        continue
    key = (service, instance, node, port)
    if key in seen:
        continue
    seen.add(key)
    print("service %-6d instance %-8d node %-3d port %d" % key)

print("total: %d" % len(seen))
