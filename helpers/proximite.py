#!/usr/bin/env python3
"""Proximite derivee des canaux bruts du TCS3701.

Pourquoi pas le sous-capteur proximite de SEE
---------------------------------------------
Parce qu'il n'est pas le capteur de proximite de ce telephone. Le HAL
d'OxygenOS, recupere de la partition vendor, met inconditionnellement ses trois
drapeaux ultrason a 1 et teste l'ultrason en premier dans chacun des trois etats
d'ecran : cet appareil utilise la proximite ultrasonore d'Elliptic Labs, sur le
DSP audio. Le sous-capteur SEE est publie parce que la puce en a la capacite, et
personne ne le demande -- ni OxygenOS, ni nous. Voir
docs/evidence/2026-08-24-proximity-is-ultrasonic.md.

Limite de ce programme
----------------------
La meme puce voit un doigt : couvrir le capteur change ses canaux bruts d'un
facteur deux a trois. Mais elle est passive. Un telephone decouvert dans le
sombre a ensuite reproduit exactement le niveau c6=2204 classe "proche" par le
demon. L'obscurite et l'occultation ne sont donc pas separables de facon fiable
avec ces seules mesures.

Le sens du changement depend de l'eclairage : dans le noir, la reflexion
infrarouge domine et les canaux montent ; en plein jour, l'occultation domine et
ils descendent. Un seuil fixe sur une valeur absolue ne peut donc pas marcher.
On etalonne sur l'appareil, on choisit le canal qui separe le mieux, et on
decide sur un ecart relatif a une ligne de base glissante -- avec hysteresis,
pour ne pas osciller a la frontiere.

Usage:
    proximite.py --calibrer     mesure decouvert/couvert, ecrit les seuils
    proximite.py --forcer-als-experimental
                                demon passif, diagnostic uniquement
    proximite.py --etat         lit l'etat courant
"""
import ctypes
import collections
import importlib.util
import json
import os
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
def _chemin(systeme, repli):
    """Chemin systeme si on peut y ecrire, sinon un repli dans le compte.

    L'etalonnage se fait naturellement depuis la session graphique, donc en
    utilisateur ordinaire : imposer /etc ferait echouer la seule etape qui
    demande une presence humaine.
    """
    p = pathlib.Path(systeme)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        t = p.parent / (".ecriture-%d" % os.getpid())
        t.touch(); t.unlink()
        return p
    except OSError:
        q = pathlib.Path(repli).expanduser()
        q.parent.mkdir(parents=True, exist_ok=True)
        return q


SEUILS = _chemin("/etc/hotdog-proximite.json",
                 "~/.config/hotdog-proximite.json")
ETAT = _chemin("/run/hotdog-proximite", "~/.cache/hotdog-proximite")
JOURNAL = _chemin("/var/log/hotdog-proximite.log",
                  "~/.cache/hotdog-proximite.log")

_spec = importlib.util.spec_from_file_location("ssc_client", CLIENT)
SSC = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(SSC)

EVT_ECHANTILLON = 1025
CADENCE = 5.0

VERT, ROUGE, JAUNE, GRAS, NEUTRE = (
    "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m")
if not sys.stdout.isatty():
    VERT = ROUGE = JAUNE = GRAS = NEUTRE = ""


def suid_lumiere():
    sortie = subprocess.run([sys.executable, str(CLIENT), "ambient_light"],
                            capture_output=True, text=True, timeout=25).stdout
    m = re.search(r"data-type 'ambient_light': ([0-9a-f]{32})", sortie)
    return m.group(1) if m else None


class Flux:
    """Abonnement continu a la lumiere ambiante."""

    def __init__(self, suid, rate=CADENCE):
        bas, haut = int(suid[16:], 16), int(suid[:16], 16)
        self.fd = SSC.libc.socket(SSC.AF_QIPCRTR, socket.SOCK_DGRAM, 0)
        for canal in range(12):
            a = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, canal, 0)
            if SSC.libc.bind(self.fd, ctypes.byref(a), ctypes.sizeof(a)) == 0:
                break
        noeud, port = SSC.find_service()
        cfg = SSC.pb_bytes(2, SSC.field(1, 5, struct.pack("<f", rate)))
        corps = (SSC.pb_bytes(1, SSC.suid_msg(bas, haut))
                 + SSC.field(2, 5, struct.pack("<I", 513))
                 + SSC.pb_bytes(3, SSC.pb_uint(1, 1) + SSC.pb_uint(2, 0))
                 + SSC.pb_bytes(4, cfg))
        pkt = SSC.qmi_request(1, SSC.SNS_CLIENT_REQ, corps)
        dst = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, noeud, port)
        SSC.libc.sendto(self.fd, ctypes.create_string_buffer(pkt), len(pkt), 0,
                        ctypes.byref(dst), ctypes.sizeof(dst))
        SSC.libc.setsockopt(self.fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                            struct.pack("qq", 0, 100000), 16)
        self.buf = ctypes.create_string_buffer(4096)

    def echantillons(self):
        out = []
        for _ in range(16):
            n = SSC.libc.recv(self.fd, self.buf, 4096, 0)
            if n <= 0:
                break
            d = self.buf.raw[:n]
            pos = -1
            while True:
                pos = d.find(b"\x0d", pos + 1)
                if pos < 0 or pos + 5 > len(d):
                    break
                # l'evenement d'etalonnage 1022 porte un vecteur de biais
                # souvent nul : le prendre pour un echantillon donne un capteur
                # mort. On exige l'evenement d'echantillon.
                if struct.unpack_from("<I", d, pos + 1)[0] != EVT_ECHANTILLON:
                    continue
                t = d.find(b"\x0a", pos)
                if not (0 < t < pos + 40) or t + 2 >= len(d):
                    continue
                ln = d[t + 1]
                if ln % 4 == 0 and 4 <= ln <= 64 and t + 2 + ln <= len(d):
                    out.append(list(struct.unpack_from(
                        "<%df" % (ln // 4), d, t + 2)))
        return out

    def fermer(self):
        SSC.libc.close(self.fd)


def moyenne(vecteurs, i):
    vals = [v[i] for v in vecteurs if len(v) > i]
    return sum(vals) / len(vals) if vals else 0.0


def mediane(valeurs):
    valeurs = sorted(valeurs)
    return valeurs[len(valeurs) // 2]


def parametres_detection(seuils=None):
    """Retourne canal, sens et rapports d'hysteresis.

    Le rapport est toujours superieur a un: ``courant/base`` quand couvrir
    fait monter le canal, ``base/courant`` quand cela le fait descendre.
    """
    canal, sens = 6, 1
    rapport = 1.92
    if seuils:
        canal = int(seuils.get("canal", canal))
        loin = float(seuils.get("loin", 0))
        proche = float(seuils.get("proche", 0))
        if loin > 0 and proche > 0 and loin != proche:
            sens = 1 if proche > loin else -1
            rapport = proche / loin if sens > 0 else loin / proche
    r_proche = 1.0 + (rapport - 1.0) * 0.55
    r_loin = 1.0 + (rapport - 1.0) * 0.30
    return canal, sens, r_proche, r_loin


class Detecteur:
    """Filtre median, ligne de base glissante et hysteresis."""

    def __init__(self, sens, r_proche, r_loin, base_initiale=None):
        self.sens = sens
        self.r_proche = r_proche
        self.r_loin = r_loin
        self.fenetre = collections.deque(maxlen=5)
        self.base_ech = collections.deque(maxlen=150)
        if base_initiale is not None and base_initiale > 0:
            self.base_ech.extend([float(base_initiale)] * 5)
        self.etat = False
        self.courant = None
        self.base = None
        self.rapport = None

    def ajouter(self, valeur):
        self.fenetre.append(float(valeur))
        if len(self.fenetre) < 3:
            return None

        self.courant = mediane(self.fenetre)
        if len(self.base_ech) < 5:
            self.base_ech.append(self.courant)
            return None

        self.base = mediane(self.base_ech)
        if self.courant <= 0 or self.base <= 0:
            return None
        if self.sens > 0:
            self.rapport = self.courant / self.base
        else:
            self.rapport = self.base / self.courant

        nouvel_etat = (self.rapport > self.r_proche if not self.etat
                       else self.rapport > self.r_loin)
        changement = nouvel_etat != self.etat
        self.etat = nouvel_etat

        # Ne jamais incorporer l'echantillon qui vient de declencher "near".
        # La base ne suit que le regime que nous avons effectivement classe loin.
        if not self.etat:
            self.base_ech.append(self.courant)
        return self.etat if changement else None


def recolter(flux, secs, etiquette):
    print("  %s%s%s" % (JAUNE, etiquette, NEUTRE))
    ech = []
    fin = time.time() + secs
    affiche = -1
    while time.time() < fin:
        ech.extend(flux.echantillons())
        reste = int(fin - time.time()) + 1
        if reste != affiche:
            print("\r     %2ds  (%d echantillons) " % (reste, len(ech)),
                  end="", flush=True)
            affiche = reste
        time.sleep(0.05)
    print("\r" + " " * 40 + "\r", end="")
    return ech


def calibrer():
    suid = suid_lumiere()
    if not suid:
        sys.exit("le capteur de lumiere ne publie pas d'identifiant")
    flux = Flux(suid)
    try:
        print("%sEtalonnage de la proximite%s" % (GRAS, NEUTRE))
        loin = recolter(flux, 12, ">> Laissez le capteur DECOUVERT, en haut de "
                                  "l'ecran pres de l'ecouteur.")
        proche = recolter(flux, 12, ">> COUVREZ le capteur avec le doigt et "
                                    "maintenez.")
        if len(loin) < 10 or len(proche) < 10:
            sys.exit("pas assez d'echantillons ; le capteur diffuse-t-il ?")

        n = min(len(loin[0]), len(proche[0]))
        print("  canal      loin      proche    separation")
        meilleur, score_max = None, 0.0
        for i in range(n):
            a, b = moyenne(loin, i), moyenne(proche, i)
            # separation relative : robuste aux niveaux d'eclairage absolus
            base = max(abs(a), 1.0)
            score = abs(b - a) / base
            print("  c%-8d %9.1f %9.1f %9.2f" % (i, a, b, score))
            if score > score_max:
                meilleur, score_max = i, score
        if meilleur is None or score_max < 0.25:
            sys.exit("aucun canal ne separe assez nettement (%.2f) ; refaites "
                     "l'etalonnage en couvrant bien le capteur" % score_max)

        a, b = moyenne(loin, meilleur), moyenne(proche, meilleur)
        # deux seuils, pour une hysteresis : on bascule a 60 % du chemin dans
        # le sens de l'approche, a 40 % dans l'autre
        seuils = {
            "canal": meilleur,
            "loin": a,
            "proche": b,
            "sens": 1 if b > a else -1,
            "seuil_proche": a + (b - a) * 0.6,
            "seuil_loin": a + (b - a) * 0.4,
            "separation": score_max,
            "date": time.strftime("%F %T"),
        }
        SEUILS.write_text(json.dumps(seuils, indent=2))
        print("\n  %scanal c%d retenu%s, separation %.2f"
              % (VERT, meilleur, NEUTRE, score_max))
        if seuils["sens"] > 0:
            print("  proche au-dela de %.1f, loin en deca de %.1f"
                  % (seuils["seuil_proche"], seuils["seuil_loin"]))
        else:
            print("  proche en deca de %.1f, loin au-dela de %.1f"
                  % (seuils["seuil_proche"], seuils["seuil_loin"]))
        print("  seuils ecrits dans %s" % SEUILS)
        return 0
    finally:
        flux.fermer()


def demon():
    """Detection sur ligne de base glissante, pas sur seuil absolu.

    Deux lecons de la trace des canaux :

    - c6 commence par un echantillon aberrant a 64 avant de se stabiliser vers
      1050. Decider sur un echantillon isole est donc fragile ; on decide sur
      la mediane d'une courte fenetre.
    - un seuil absolu etalonne a un instant donne ne survit pas a un changement
      d'eclairage. Une ligne de base glissante limite ce probleme, mais ne peut
      pas distinguer un passage brusque dans le sombre d'une occultation.

    L'etalonnage sert alors a mesurer le RAPPORT couvert/decouvert, pas des
    valeurs : sur l'exemplaire de developpement il vaut 1.92, d'ou des bascules
    a 1.5 et 1.25 qui laissent de la marge des deux cotes.
    """
    src = SEUILS
    if not src.exists():
        for autre in ("/etc/hotdog-proximite.json",
                      "/home/user/.config/hotdog-proximite.json"):
            if pathlib.Path(autre).exists():
                src = pathlib.Path(autre); break
    seuils = None
    if src.exists():
        seuils = json.loads(src.read_text())
    canal, sens, r_proche, r_loin = parametres_detection(seuils)

    suid = suid_lumiere()
    if not suid:
        sys.exit("le capteur de lumiere ne publie pas d'identifiant")
    flux = Flux(suid)
    jrn = open(JOURNAL, "a")
    base_initiale = None
    if seuils and float(seuils.get("loin", 0)) > 0:
        base_initiale = float(seuils["loin"])
    detecteur = Detecteur(sens, r_proche, r_loin, base_initiale)
    ETAT.write_text("unknown\n")
    jrn.write("--- %s demarrage, canal c%d, sens=%s, proche x%.2f, loin x%.2f\n"
              % (time.strftime("%F %T"), canal,
                 "hausse" if sens > 0 else "baisse", r_proche, r_loin))
    jrn.flush()

    battement = 0.0
    etat_publie = None
    try:
        while True:
            for v in flux.echantillons():
                if len(v) <= canal:
                    continue
                changement = detecteur.ajouter(v[canal])
                if (detecteur.rapport is not None
                        and detecteur.etat != etat_publie):
                    etat_publie = detecteur.etat
                    ETAT.write_text("near\n" if etat_publie else "far\n")
                    jrn.write("%s %-5s c%d=%.0f base=%.0f rapport=%.2f\n"
                              % (time.strftime("%T"),
                                 "near" if etat_publie else "far", canal,
                                 detecteur.courant, detecteur.base,
                                 detecteur.rapport))
                    jrn.flush()
            # un battement periodique, pour pouvoir diagnostiquer a distance
            # sans demander un geste a qui que ce soit
            if time.time() - battement > 15:
                battement = time.time()
                if detecteur.base is not None:
                    jrn.write("%s .     c%d=%.0f base=%.0f rapport=%.2f etat=%s\n"
                              % (time.strftime("%T"), canal, detecteur.courant,
                                 detecteur.base, detecteur.rapport,
                                 "near" if detecteur.etat else "far"))
                else:
                    jrn.write("%s .     pas encore d'echantillons\n"
                              % time.strftime("%T"))
                jrn.flush()
            time.sleep(0.05)
    finally:
        flux.fermer()
        ETAT.write_text("unknown\n")
        jrn.close()


def main():
    if "--calibrer" in sys.argv:
        return calibrer()
    if "--etat" in sys.argv:
        print(ETAT.read_text().strip() if ETAT.exists() else "inconnu")
        return 0
    if "--forcer-als-experimental" not in sys.argv:
        sys.exit("demon ALS desactive : un telephone decouvert dans le sombre "
                 "produit le meme signal qu'une occultation. Utilisez "
                 "--forcer-als-experimental seulement pour le diagnostic ; "
                 "la proximite reelle est l'ultrason Elliptic sur l'ADSP.")
    return demon()


if __name__ == "__main__":
    sys.exit(main())
