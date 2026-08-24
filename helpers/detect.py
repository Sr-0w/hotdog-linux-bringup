#!/usr/bin/env python3
"""Detecte ce qui reagit a un geste, en s'abonnant a tout ce que SEE publie.

L'idee est de ne rien supposer : on s'abonne a chaque type de donnee qui a un
identifiant, on guide l'utilisateur a travers une serie de gestes, et on
journalise tout ce qui arrive avec la phase pendant laquelle c'est arrive. Ce
qui reagit au geste apparait dans le journal, y compris des capteurs auxquels on
n'avait pas pense.

Ecrit parce que le SAR et la proximite acceptent leurs requetes sans jamais
emettre : si un autre capteur bouge quand on approche la main du bas ou du haut
du telephone, la puce est lue par quelqu'un et le probleme est en aval.

Le journal va dans detect.log, a cote du script.

Usage:
    python3 detect.py            la sequence complete
    python3 detect.py --court    seulement les deux gestes capteurs
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
JOURNAL = HERE / "detect.log"

_spec = importlib.util.spec_from_file_location("ssc_client", CLIENT)
SSC = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(SSC)

MSG_STREAM = 513
MSG_ON_CHANGE = 514
EVT = {130: "erreur", 768: "config", 1022: "calib", 1025: "echantillon"}

# tout ce que le firmware peut publier ; ceux sans identifiant sont ignores
TYPES = [
    ("accel", MSG_STREAM, 25.0), ("gyro", MSG_STREAM, 25.0),
    ("mag", MSG_STREAM, 25.0), ("sensor_temperature", MSG_STREAM, 5.0),
    ("ambient_light", MSG_STREAM, 5.0),
    ("proximity", MSG_ON_CHANGE, None), ("sars", MSG_ON_CHANGE, None),
    ("amd", MSG_ON_CHANGE, None), ("rmd", MSG_ON_CHANGE, None),
    ("tilt", MSG_ON_CHANGE, None), ("device_orient", MSG_ON_CHANGE, None),
    ("rgb", MSG_STREAM, 5.0), ("cct", MSG_STREAM, 5.0),
    ("wise_light", MSG_ON_CHANGE, None), ("hall", MSG_ON_CHANGE, None),
]

PHASES = [
    ("repos", "Posez le telephone a plat et ne le touchez plus.", 10),
    ("main-bas", "Posez la paume sur le BAS du telephone et tenez.", 12),
    ("retrait-bas", "Retirez la main.", 6),
    ("doigt-haut", "Posez le doigt en HAUT de l'ecran, pres de l'ecouteur.", 12),
    ("retrait-haut", "Retirez le doigt.", 6),
    ("vertical", "Tenez le telephone droit, haut vers le haut.", 8),
    ("agite", "Agitez le telephone.", 8),
    ("repos-final", "Reposez-le a plat.", 6),
]
PHASES_COURTES = [PHASES[0], PHASES[1], PHASES[2], PHASES[3], PHASES[4]]

VERT, ROUGE, JAUNE, GRAS, NEUTRE = (
    "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m")
if not sys.stdout.isatty():
    VERT = ROUGE = JAUNE = GRAS = NEUTRE = ""


def suid_de(t):
    try:
        s = subprocess.run([sys.executable, str(CLIENT), t],
                           capture_output=True, text=True, timeout=25).stdout
    except subprocess.TimeoutExpired:
        return None
    m = re.search(r"data-type '%s': ([0-9a-f]{32})" % re.escape(t), s)
    return m.group(1) if m else None


def decoder(d):
    """Rend [(id_message, [valeurs])] pour toute indication SEE.

    Chaque capteur a son PROPRE identifiant d'evenement : 772 pour amd, 776
    pour device_orient, 1026 pour le SAR, 1025 pour le generique. Un decodeur
    qui n'accepte que 1025 jette les donnees de tous les autres et les fait
    passer pour muets -- c'est ce que faisaient mes outils, et cela a produit
    plusieurs faux "capteur mort" sur des capteurs qui emettaient.

    Structure de l'indication : champ 2 enveloppe { 0x0d id fixed32,
    0x11 horodatage fixed64, 0x1a charge }, la charge portant soit un tableau
    de flottants empaquetes (0x0a), soit un entier (0x08).
    """
    out = []
    pos = -1
    while True:
        pos = d.find(b"\x0d", pos + 1)
        if pos < 0 or pos + 5 > len(d):
            break
        mid = struct.unpack_from("<I", d, pos + 1)[0]
        if not (100 <= mid <= 2048):
            continue
        # 1022 est l'evenement d'etalonnage : son vecteur de biais, souvent
        # nul, se lit comme un capteur mort si on le prend pour un echantillon
        if mid == 1022:
            out.append((mid, []))
            continue
        vals = []
        # la charge suit l'horodatage, dans une fenetre courte
        t = d.find(b"\x1a", pos, min(len(d), pos + 24))
        if t >= 0 and t + 2 < len(d):
            n = d[t + 1]
            corps = d[t + 2:t + 2 + n]
            if corps[:1] == b"\x0a" and len(corps) > 1:
                m = corps[1]
                if m % 4 == 0 and 4 <= m <= 48 and 2 + m <= len(corps):
                    vals = list(struct.unpack_from("<%df" % (m // 4), corps, 2))
            elif corps[:1] == b"\x08" and len(corps) > 1:
                vals = [float(corps[1])]
        out.append((mid, vals))
    return out


class Abonnement:
    def __init__(self, nom, suid, msgid, rate):
        self.nom = nom
        bas, haut = int(suid[16:], 16), int(suid[:16], 16)
        self.fd = SSC.libc.socket(SSC.AF_QIPCRTR, socket.SOCK_DGRAM, 0)
        for c in range(12):
            a = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, c, 0)
            if SSC.libc.bind(self.fd, ctypes.byref(a), ctypes.sizeof(a)) == 0:
                break
        noeud, port = SSC.find_service()
        charge = (SSC.pb_bytes(2, SSC.field(1, 5, struct.pack("<f", rate)))
                  if rate else b"")
        corps = (SSC.pb_bytes(1, SSC.suid_msg(bas, haut))
                 + SSC.field(2, 5, struct.pack("<I", msgid))
                 + SSC.pb_bytes(3, SSC.pb_uint(1, 1) + SSC.pb_uint(2, 0))
                 + SSC.pb_bytes(4, charge))
        pkt = SSC.qmi_request(1, SSC.SNS_CLIENT_REQ, corps)
        dst = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, noeud, port)
        SSC.libc.sendto(self.fd, ctypes.create_string_buffer(pkt), len(pkt), 0,
                        ctypes.byref(dst), ctypes.sizeof(dst))
        SSC.libc.setsockopt(self.fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                            struct.pack("qq", 0, 20000), 16)
        self.buf = ctypes.create_string_buffer(4096)
        self.octets = 0

    def lire(self):
        ev = []
        for _ in range(24):
            n = SSC.libc.recv(self.fd, self.buf, 4096, 0)
            if n <= 0:
                break
            self.octets += n
            ev.extend(decoder(self.buf.raw[:n]))
        return ev

    def fermer(self):
        SSC.libc.close(self.fd)


def main():
    court = "--court" in sys.argv
    phases = PHASES_COURTES if court else PHASES
    jrn = open(JOURNAL, "w")

    def note(txt):
        jrn.write(txt + "\n")
        jrn.flush()

    note("# detect.py  %s" % time.strftime("%F %T"))
    print("%sDetection par le geste%s" % (GRAS, NEUTRE))
    print("Journal : %s\n" % JOURNAL)

    print("Recherche des capteurs publies...")
    flux = []
    for nom, msgid, rate in TYPES:
        u = suid_de(nom)
        note("suid %-20s %s" % (nom, u or "aucun"))
        if not u:
            continue
        try:
            flux.append(Abonnement(nom, u, msgid, rate))
        except Exception as e:                            # noqa: BLE001
            note("abonnement %s echoue: %s" % (nom, e))
    print("  %d capteurs abonnes : %s\n"
          % (len(flux), ", ".join(f.nom for f in flux)))
    note("abonnes: %s" % ", ".join(f.nom for f in flux))

    # etat courant par capteur, pour ne journaliser que les changements reels
    dernier = {}
    resume = {}

    for etiquette, consigne, duree in phases:
        print("%s>> %s%s" % (JAUNE, consigne, NEUTRE))
        note("\n== phase %s : %s" % (etiquette, consigne))
        resume.setdefault(etiquette, {})
        fin = time.time() + duree
        affiche = -1
        while time.time() < fin:
            reste = int(fin - time.time()) + 1
            for f in flux:
                for mid, vals in f.lire():
                    r = resume[etiquette].setdefault(
                        f.nom, {"evenements": 0, "changements": 0, "min": None,
                                "max": None})
                    r["evenements"] += 1
                    if mid != 1025 or not vals:
                        note("%-16s %-12s %s" % (f.nom, EVT[mid], ""))
                        continue
                    arr = [round(v, 3) for v in vals[:4]]
                    prec = dernier.get(f.nom)
                    bouge = prec is None or any(
                        abs(a - b) > 0.02 for a, b in zip(arr, prec))
                    if bouge:
                        r["changements"] += 1
                        note("%-16s %s" % (f.nom, arr))
                        dernier[f.nom] = arr
                    n0 = arr[0]
                    r["min"] = n0 if r["min"] is None else min(r["min"], n0)
                    r["max"] = n0 if r["max"] is None else max(r["max"], n0)
            # n'ecrire qu'au changement de seconde, sinon le compte a
            # rebours se reecrit vingt fois par seconde et noie la consigne
            if reste != affiche:
                print("\r   %2ds " % reste, end="", flush=True)
                affiche = reste
            time.sleep(0.05)
        print("\r        \r", end="")

    for f in flux:
        note("octets %-20s %d" % (f.nom, f.octets))
        f.fermer()

    print("\n%sResume : ce qui a bouge, par phase%s" % (GRAS, NEUTRE))
    note("\n== resume")
    base = resume.get(phases[0][0], {})
    for etiquette, _, _ in phases:
        actifs = [(n, r) for n, r in resume.get(etiquette, {}).items()
                  if r["changements"] > 0]
        morceaux = []
        for n, r in actifs:
            b = base.get(n)
            # un ecart net par rapport au repos est ce qui compte : le reste
            # est du bruit de mesure
            marque = ""
            if b and b["min"] is not None and r["min"] is not None:
                if r["min"] > b["max"] or r["max"] < b["min"]:
                    marque = " <<<"
            morceaux.append("%s(%.1f..%.1f)%s" % (n, r["min"], r["max"], marque))
        ligne = "  %-14s %s" % (etiquette, ", ".join(morceaux) or "rien")
        print(ligne)
        note(ligne)
    muets = [n for n, _, _ in TYPES
             if n not in {k for p in resume.values() for k in p}]
    ligne = "  muets: %s" % (", ".join(muets) or "aucun")
    print(ligne); note(ligne)

    print("\nJournal complet : %s" % JOURNAL)
    jrn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
