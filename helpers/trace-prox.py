#!/usr/bin/env python3
"""Enregistre les dix canaux du TCS3701 pendant que vous couvrez le capteur.

Ecrit pour ne rien avoir a synchroniser : lancez, couvrez et decouvrez au
rythme qui vous arrange, le fichier garde tout avec l'horodatage. L'analyse se
fait apres coup sur le journal, pas en direct.

Journal : trace-prox.log, a cote du script.

Usage:
    trace-prox.py           soixante secondes
    trace-prox.py 120       duree choisie, en secondes
"""
import ctypes
import importlib.util
import pathlib
import re
import socket
import struct
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
CLIENT = HERE / "ssc-client.py"
if not CLIENT.exists():
    CLIENT = pathlib.Path("/root/ssc-client.py")
JOURNAL = HERE / "trace-prox.log"

_spec = importlib.util.spec_from_file_location("ssc_client", CLIENT)
SSC = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(SSC)

EVT = 1025


def suid_lumiere():
    s = subprocess.run([sys.executable, str(CLIENT), "ambient_light"],
                       capture_output=True, text=True, timeout=25).stdout
    m = re.search(r"data-type 'ambient_light': ([0-9a-f]{32})", s)
    return m.group(1) if m else None


def flux(suid, rate=5.0):
    bas, haut = int(suid[16:], 16), int(suid[:16], 16)
    fd = SSC.libc.socket(SSC.AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    for c in range(12):
        a = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, c, 0)
        if SSC.libc.bind(fd, ctypes.byref(a), ctypes.sizeof(a)) == 0:
            break
    noeud, port = SSC.find_service()
    cfg = SSC.pb_bytes(2, SSC.field(1, 5, struct.pack("<f", rate)))
    corps = (SSC.pb_bytes(1, SSC.suid_msg(bas, haut))
             + SSC.field(2, 5, struct.pack("<I", 513))
             + SSC.pb_bytes(3, SSC.pb_uint(1, 1) + SSC.pb_uint(2, 0))
             + SSC.pb_bytes(4, cfg))
    pkt = SSC.qmi_request(1, SSC.SNS_CLIENT_REQ, corps)
    dst = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, noeud, port)
    SSC.libc.sendto(fd, ctypes.create_string_buffer(pkt), len(pkt), 0,
                    ctypes.byref(dst), ctypes.sizeof(dst))
    SSC.libc.setsockopt(fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                        struct.pack("qq", 0, 200000), 16)
    return fd


def lire(fd, buf):
    out = []
    for _ in range(16):
        n = SSC.libc.recv(fd, buf, 4096, 0)
        if n <= 0:
            break
        d = buf.raw[:n]
        pos = -1
        while True:
            pos = d.find(b"\x0d", pos + 1)
            if pos < 0 or pos + 5 > len(d):
                break
            # 1022 est l'evenement d'etalonnage, pas un echantillon
            if struct.unpack_from("<I", d, pos + 1)[0] != EVT:
                continue
            t = d.find(b"\x0a", pos)
            if not (0 < t < pos + 40) or t + 2 >= len(d):
                continue
            ln = d[t + 1]
            if ln % 4 == 0 and 4 <= ln <= 64 and t + 2 + ln <= len(d):
                out.append(list(struct.unpack_from("<%df" % (ln // 4), d, t + 2)))
    return out


def main():
    duree = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
    suid = suid_lumiere()
    if not suid:
        sys.exit("le capteur de lumiere ne publie pas d'identifiant")
    fd = flux(suid)
    buf = ctypes.create_string_buffer(4096)
    j = open(JOURNAL, "w")
    j.write("# trace-prox %s  duree %gs\n" % (time.strftime("%F %T"), duree))
    j.write("# t_ms  c0..c9\n")

    print("\033[1mTrace des canaux du capteur\033[0m")
    print("Journal : %s\n" % JOURNAL)
    print("\033[33m>> Couvrez et decouvrez le capteur plusieurs fois, a votre")
    print("   rythme, pendant %d secondes. Rien a synchroniser.\033[0m\n" % duree)

    t0 = time.time()
    fin = t0 + duree
    n = 0
    dernier = None
    affiche = -1
    while time.time() < fin:
        for v in lire(fd, buf):
            n += 1
            dernier = v
            j.write("%8.0f  %s\n" % ((time.time() - t0) * 1000,
                                     " ".join("%.1f" % x for x in v)))
        reste = int(fin - time.time()) + 1
        if reste != affiche:
            j.flush()
            if dernier and len(dernier) > 6:
                # une barre grossiere pour que l'effet se voie a l'oeil
                barre = int(min(dernier[6], 4000) / 100)
                print("\r  %3ds  c6=%7.1f  %-40s" % (reste, dernier[6],
                                                     "#" * barre), end="",
                      flush=True)
            else:
                print("\r  %3ds  en attente d'echantillons     " % reste,
                      end="", flush=True)
            affiche = reste
        time.sleep(0.05)

    SSC.libc.close(fd)
    j.write("# %d echantillons\n" % n)
    j.close()
    print("\n\n%d echantillons ecrits dans %s" % (n, JOURNAL))
    return 0 if n else 1


if __name__ == "__main__":
    sys.exit(main())
