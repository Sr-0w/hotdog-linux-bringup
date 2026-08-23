#!/usr/bin/env python3
"""Flux continu SEE. Enveloppe correcte :
   sns_client_request_msg{ suid=1, msg_id=2 fixed32, susp_config=3,
                           request=4 -> sns_std_request{ payload=2 bytes } }
   la charge etant sns_std_sensor_config{ sample_rate=1 float }."""
import ctypes, importlib.util, pathlib, socket, struct, sys, time
HERE = pathlib.Path(__file__).resolve().parent
SP = importlib.util.spec_from_file_location("ssc_client", HERE / "ssc-client.py")
SSC = importlib.util.module_from_spec(SP); SP.loader.exec_module(SSC)
txt, secs = sys.argv[1], float(sys.argv[2])
rate = float(sys.argv[3]) if len(sys.argv) > 3 else 25.0
low, high = int(txt[16:], 16), int(txt[:16], 16)
node, port = SSC.find_service()
fd = SSC.libc.socket(SSC.AF_QIPCRTR, socket.SOCK_DGRAM, 0)
for c in range(12):
    a = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, c, 0)
    if SSC.libc.bind(fd, ctypes.byref(a), ctypes.sizeof(a)) == 0: break
susp = SSC.pb_uint(1, 1) + SSC.pb_uint(2, 0)
cfg  = SSC.field(1, 5, struct.pack("<f", rate))
body = (SSC.pb_bytes(1, SSC.suid_msg(low, high))
        + SSC.field(2, 5, struct.pack("<I", 513))
        + SSC.pb_bytes(3, susp)
        + SSC.pb_bytes(4, SSC.pb_bytes(2, cfg)))
pkt = SSC.qmi_request(1, SSC.SNS_CLIENT_REQ, body)
dst = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, node, port)
SSC.libc.sendto(fd, ctypes.create_string_buffer(pkt), len(pkt), 0,
                ctypes.byref(dst), ctypes.sizeof(dst))
SSC.libc.setsockopt(fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO, struct.pack("qq", 2, 0), 16)
rb = ctypes.create_string_buffer(4096); end = time.time() + secs; n = 0; shown = 0
while time.time() < end:
    r = SSC.libc.recv(fd, rb, 4096, 0)
    if r <= 0: continue
    d = rb.raw[:r]
    # trouver le motif  1a LL 0a 0c <12 octets>  (event field3 -> data field1)
    i = 0
    while True:
        i = d.find(b"\x0a\x0c", i + 1)
        if i < 0 or i + 14 > len(d): break
        v = struct.unpack("<3f", d[i+2:i+14])
        if all(abs(x) < 1e4 for x in v):
            n += 1
            if shown < 4:
                print("   x=%9.4f  y=%9.4f  z=%9.4f" % v); shown += 1
print("   echantillons: %d en %.0f s" % (n, secs))
