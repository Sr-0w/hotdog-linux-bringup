#!/usr/bin/env python3
"""Test guide des capteurs du OnePlus 7T Pro sous mainline.

Chaque capteur a une epreuve : le programme dit quoi faire, puis valide tout
seul des que la condition est remplie, ou echoue au bout du delai. Rien a
interpreter a l'oeil.

Les capteurs sont lus directement par SEE, en QMI sur QRTR, sans passer par
iio-sensor-proxy -- sauf l'epreuve d'integration finale, qui verifie justement
que le pont vers le systeme fonctionne.

Usage:
    hotdog-sensor-check.py            toutes les epreuves
    hotdog-sensor-check.py accel gyro seulement celles nommees
    hotdog-sensor-check.py --list     lister les epreuves
    hotdog-sensor-check.py --passif   sauter tout ce qui demande un geste
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

_spec = importlib.util.spec_from_file_location("ssc_client", CLIENT)
SSC = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(SSC)

MSG_STD_SENSOR_CONFIG = 513      # flux continu
MSG_STD_ON_CHANGE_CONFIG = 514   # a evenement
EVENT_SAMPLE = 1025

VERT, ROUGE, JAUNE, GRAS, NEUTRE = (
    "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m")
if not sys.stdout.isatty():
    VERT = ROUGE = JAUNE = GRAS = NEUTRE = ""


def suid_de(type_donnee):
    """Identifiant du capteur fournissant ce type, ou None."""
    try:
        sortie = subprocess.run(
            [sys.executable, str(CLIENT), type_donnee],
            capture_output=True, text=True, timeout=25).stdout
    except subprocess.TimeoutExpired:
        return None
    trouve = re.search(
        r"data-type '%s': ([0-9a-f]{32})" % re.escape(type_donnee), sortie)
    return trouve.group(1) if trouve else None


class Flux:
    """Abonnement SEE. Rend des listes de flottants, un element par echantillon."""

    def __init__(self, suid, msgid=MSG_STD_SENSOR_CONFIG, rate=25.0):
        bas, haut = int(suid[16:], 16), int(suid[:16], 16)
        self.fd = SSC.libc.socket(SSC.AF_QIPCRTR, socket.SOCK_DGRAM, 0)
        for canal in range(12):
            adr = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, canal, 0)
            if SSC.libc.bind(self.fd, ctypes.byref(adr), ctypes.sizeof(adr)) == 0:
                break
        noeud, port = SSC.find_service()
        charge = (SSC.pb_bytes(2, SSC.field(1, 5, struct.pack("<f", rate)))
                  if rate else b"")
        corps = (SSC.pb_bytes(1, SSC.suid_msg(bas, haut))
                 + SSC.field(2, 5, struct.pack("<I", msgid))
                 + SSC.pb_bytes(3, SSC.pb_uint(1, 1) + SSC.pb_uint(2, 0))
                 + SSC.pb_bytes(4, charge))
        paquet = SSC.qmi_request(1, SSC.SNS_CLIENT_REQ, corps)
        dest = SSC.SockaddrQrtr(SSC.AF_QIPCRTR, noeud, port)
        SSC.libc.sendto(self.fd, ctypes.create_string_buffer(paquet),
                        len(paquet), 0, ctypes.byref(dest), ctypes.sizeof(dest))
        # lecture non bloquante courte : la boucle d'epreuve cadence elle-meme
        SSC.libc.setsockopt(self.fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                            struct.pack("qq", 0, 50000), 16)
        self.tampon = ctypes.create_string_buffer(4096)

    def echantillons(self):
        """Vide ce qui est arrive depuis le dernier appel."""
        sortie = []
        for _ in range(48):
            recu = SSC.libc.recv(self.fd, self.tampon, 4096, 0)
            if recu <= 0:
                break
            sortie.extend(self._decoder(self.tampon.raw[:recu]))
        return sortie

    @staticmethod
    def _decoder(donnees):
        """Extrait les vecteurs des evenements d'echantillon (message 1025).

        On exige l'identifiant de message : un filtre plus lache attrape
        l'evenement d'etalonnage, dont le biais nul se lit comme un capteur
        mort. Cette erreur a produit un faux "magnetometre a zero" alors qu'il
        mesurait 168 uT.
        """
        vecteurs = []
        pos = -1
        while True:
            pos = donnees.find(b"\x0d", pos + 1)
            if pos < 0 or pos + 5 > len(donnees):
                break
            if struct.unpack_from("<I", donnees, pos + 1)[0] != EVENT_SAMPLE:
                continue
            tete = donnees.find(b"\x0a", pos)
            if not (0 < tete < pos + 40) or tete + 2 >= len(donnees):
                continue
            longueur = donnees[tete + 1]
            if 4 <= longueur <= 48 and longueur % 4 == 0 \
                    and tete + 2 + longueur <= len(donnees):
                vecteurs.append(list(struct.unpack_from(
                    "<%df" % (longueur // 4), donnees, tete + 2)))
        return vecteurs

    def fermer(self):
        SSC.libc.close(self.fd)


def norme(vecteur):
    return sum(composante * composante for composante in vecteur) ** 0.5


def epreuve(titre, consigne, flux, predicat, delai=25, indice=None):
    """Affiche la consigne, attend que le predicat soit vrai, rend un verdict.

    `predicat(echantillons)` recoit tout ce qui est arrive depuis le debut et
    rend True des que la condition est remplie.
    """
    print("\n%s%s%s" % (GRAS, titre, NEUTRE))
    if consigne:
        print("  %s>> %s%s" % (JAUNE, consigne, NEUTRE))
    tous = []
    debut = time.time()
    dernier_affichage = 0.0
    while time.time() - debut < delai:
        nouveaux = flux.echantillons()
        tous.extend(nouveaux)
        if predicat(tous):
            reste = time.time() - debut
            apercu = indice(tous) if indice else ""
            print("  %sOK%s  en %.1f s  %s" % (VERT, NEUTRE, reste, apercu))
            return True, tous
        maintenant = time.time()
        if maintenant - dernier_affichage > 1.0:
            apercu = indice(tous) if indice and tous else "en attente"
            print("     %-58s  %2ds restantes\r" % (
                apercu, int(delai - (maintenant - debut))), end="", flush=True)
            dernier_affichage = maintenant
        time.sleep(0.05)
    apercu = indice(tous) if indice and tous else "aucun echantillon"
    print("  %sECHEC%s  apres %d s  %s%s" % (
        ROUGE, NEUTRE, delai, apercu, " " * 20))
    return False, tous


# ---------------------------------------------------------------- epreuves

def test_accel(passif):
    suid = suid_de("accel")
    if not suid:
        return None, "pas de SUID"
    flux = Flux(suid, rate=25.0)
    try:
        apercu = lambda e: "x=%+6.2f y=%+6.2f z=%+6.2f m/s2" % tuple(e[-1][:3])
        ok1, _ = epreuve(
            "Accelerometre - gravite a plat",
            "Posez le telephone a plat sur la table, ecran vers le haut.",
            flux,
            lambda e: len(e) > 5 and e[-1][2] > 9.0 and abs(e[-1][0]) < 2.5
                      and abs(e[-1][1]) < 2.5,
            indice=apercu)
        if passif:
            return ok1, "a plat seulement (mode passif)"
        ok2, _ = epreuve(
            "Accelerometre - axe vertical",
            "Redressez le telephone, le haut vers le plafond.",
            flux,
            lambda e: len(e) > 5 and e[-1][1] > 8.0,
            indice=apercu)
        return ok1 and ok2, "gravite correcte sur Z puis sur Y"
    finally:
        flux.fermer()


def test_gyro(passif):
    suid = suid_de("gyro")
    if not suid:
        return None, "pas de SUID"
    flux = Flux(suid, rate=25.0)
    try:
        apercu = lambda e: "|w| = %5.2f rad/s" % norme(e[-1][:3])
        if passif:
            ok, _ = epreuve("Gyroscope - repos", "Ne touchez pas le telephone.",
                            flux, lambda e: len(e) > 20, delai=12, indice=apercu)
            return ok, "flux present"
        ok1, _ = epreuve(
            "Gyroscope - rotation",
            "Faites pivoter franchement le telephone dans vos mains.",
            flux, lambda e: any(norme(v[:3]) > 1.5 for v in e), indice=apercu)
        ok2, _ = epreuve(
            "Gyroscope - retour au repos",
            "Reposez le telephone et ne le touchez plus.",
            flux,
            lambda e: len(e) > 20 and all(norme(v[:3]) < 0.25 for v in e[-15:]),
            indice=apercu)
        return ok1 and ok2, "reagit a la rotation et revient au repos"
    finally:
        flux.fermer()


def test_mag(passif):
    suid = suid_de("mag")
    if not suid:
        return None, "pas de SUID"
    flux = Flux(suid, rate=25.0)
    try:
        apercu = lambda e: "|B| = %6.1f uT" % norme(e[-1][:3])
        ok1, echantillons = epreuve(
            "Magnetometre - champ present",
            "Rien a faire, on verifie que le champ terrestre est mesure.",
            flux,
            lambda e: len(e) > 5 and 15.0 < norme(e[-1][:3]) < 900.0,
            delai=15, indice=apercu)
        if passif or not ok1:
            return ok1, "champ plausible"
        base = norme(echantillons[-1][:3])
        ok2, _ = epreuve(
            "Magnetometre - reaction",
            "Tournez le telephone sur lui-meme, ou approchez un aimant.",
            flux,
            lambda e: any(abs(norme(v[:3]) - base) > 12.0 for v in e),
            indice=apercu)
        return ok2, "champ plausible et sensible au mouvement"
    finally:
        flux.fermer()


def test_temperature(passif):
    suid = suid_de("sensor_temperature")
    if not suid:
        return None, "pas de SUID"
    # la temperature de l'IMU plafonne a 5 Hz : au-dessus elle repond erreur 130
    flux = Flux(suid, rate=5.0)
    try:
        ok, _ = epreuve(
            "Temperature de l'IMU",
            "Rien a faire.",
            flux,
            lambda e: len(e) > 3 and 5.0 < e[-1][0] < 70.0,
            delai=20,
            indice=lambda e: "%.2f degres" % e[-1][0])
        return ok, "valeur plausible"
    finally:
        flux.fermer()


def test_lumiere(passif):
    suid = suid_de("ambient_light")
    if not suid:
        return None, "pas de SUID"
    flux = Flux(suid, rate=5.0)
    try:
        apercu = lambda e: "%.0f lux" % e[-1][0]
        ok1, echantillons = epreuve(
            "Lumiere ambiante - mesure",
            "Rien a faire.",
            flux, lambda e: len(e) > 3, delai=15, indice=apercu)
        if passif or not ok1:
            return ok1, "flux present"
        base = echantillons[-1][0]
        ok2, _ = epreuve(
            "Lumiere ambiante - occultation",
            "Couvrez le haut de l'ecran avec la main, pres de l'ecouteur.",
            flux,
            lambda e: any(v[0] < base * 0.5 for v in e[-40:]),
            indice=apercu)
        return ok2, "reagit a l'occultation"
    finally:
        flux.fermer()


def test_proximite(passif):
    suid = suid_de("proximity")
    if not suid:
        return None, "pas de SUID"
    flux = Flux(suid, msgid=MSG_STD_ON_CHANGE_CONFIG, rate=None)
    try:
        ok, _ = epreuve(
            "Proximite",
            "Couvrez puis decouvrez le haut de l'ecran, pres de l'ecouteur.",
            flux, lambda e: len(e) > 0, delai=20,
            indice=lambda e: "valeur %s" % e[-1][:2])
        return ok, ("evenements recus" if ok
                    else "aucun evenement -- defaut connu, voir "
                         "docs/evidence/2026-08-23-proximity-reaches-its-chip.md")
    finally:
        flux.fermer()


def test_sar(passif):
    suid = suid_de("sars")
    if not suid:
        return None, "pas de SUID"
    flux = Flux(suid, msgid=MSG_STD_ON_CHANGE_CONFIG, rate=None)
    try:
        ok, _ = epreuve(
            "Capteur SAR",
            "Posez la paume sur le bas du telephone, puis retirez-la.",
            flux, lambda e: len(e) > 0, delai=20,
            indice=lambda e: "valeur %s" % e[-1][:2])
        return ok, "evenements recus"
    finally:
        flux.fermer()


def test_mouvement(passif):
    suid = suid_de("amd")
    if not suid:
        return None, "pas de SUID"
    flux = Flux(suid, msgid=MSG_STD_ON_CHANGE_CONFIG, rate=None)
    try:
        if passif:
            return None, "demande un geste"
        ok, _ = epreuve(
            "Detection de mouvement",
            "Prenez le telephone et agitez-le quelques secondes.",
            flux, lambda e: len(e) > 0, delai=20,
            indice=lambda e: "etat %s" % e[-1][:1])
        return ok, "evenements recus"
    finally:
        flux.fermer()


def test_pont_systeme(passif):
    """Le pont vers le systeme : c'est lui qui rend les capteurs utilisables.

    Verifie AccelerometerTilt plutot que l'orientation : a plat, l'orientation
    d'ecran est legitimement indefinie, alors que l'inclinaison ne l'est que si
    le capteur ne diffuse pas.
    """
    def propriete(nom):
        try:
            sortie = subprocess.run(
                ["busctl", "--system", "get-property",
                 "net.hadess.SensorProxy", "/net/hadess/SensorProxy",
                 "net.hadess.SensorProxy", nom],
                capture_output=True, text=True, timeout=10).stdout.strip()
        except Exception:
            return None
        return sortie.split(None, 1)[1].strip('"') if " " in sortie else None

    print("\n%sPont vers le systeme (iio-sensor-proxy)%s" % (GRAS, NEUTRE))
    a_accel = propriete("HasAccelerometer")
    inclinaison = propriete("AccelerometerTilt")
    orientation = propriete("AccelerometerOrientation")
    lumiere = propriete("HasAmbientLight")
    print("  HasAccelerometer=%s  AccelerometerTilt=%s  orientation=%s  "
          "HasAmbientLight=%s" % (a_accel, inclinaison, orientation, lumiere))
    if a_accel != "true":
        print("  %sECHEC%s  le demon n'a pas enregistre l'accelerometre ; la "
              "barriere de demarrage a-t-elle tourne ?" % (ROUGE, NEUTRE))
        return False, "accelerometre absent du demon"
    if inclinaison in (None, "undefined"):
        print("  %sECHEC%s  inclinaison indefinie : personne ne diffuse, la "
              "reclamation de KWin est probablement arrivee trop tot"
              % (ROUGE, NEUTRE))
        return False, "capteur non active"
    print("  %sOK%s  le systeme recoit les echantillons" % (VERT, NEUTRE))
    return True, "inclinaison %s" % inclinaison


EPREUVES = [
    ("accel", test_accel),
    ("gyro", test_gyro),
    ("mag", test_mag),
    ("temperature", test_temperature),
    ("lumiere", test_lumiere),
    ("proximite", test_proximite),
    ("sar", test_sar),
    ("mouvement", test_mouvement),
    ("pont", test_pont_systeme),
]


def main():
    args = sys.argv[1:]
    if "--list" in args:
        for nom, _ in EPREUVES:
            print(nom)
        return 0
    passif = "--passif" in args
    voulus = [a for a in args if not a.startswith("--")]
    choisies = [(n, f) for n, f in EPREUVES if not voulus or n in voulus]
    if not choisies:
        print("aucune epreuve ne correspond : %s" % ", ".join(voulus))
        return 2

    print("%sTest guide des capteurs -- OnePlus 7T Pro, mainline%s" % (GRAS, NEUTRE))
    print("Suivez les consignes en jaune. Chaque epreuve se valide toute seule.")

    resultats = []
    for nom, fonction in choisies:
        try:
            ok, note = fonction(passif)
        except Exception as erreur:                     # noqa: BLE001
            ok, note = False, "erreur: %s" % erreur
        resultats.append((nom, ok, note))

    print("\n%sResume%s" % (GRAS, NEUTRE))
    reussis = total = 0
    for nom, ok, note in resultats:
        if ok is None:
            etat = "%sIGNORE%s" % (JAUNE, NEUTRE)
        elif ok:
            etat = "%sOK    %s" % (VERT, NEUTRE)
            reussis += 1
            total += 1
        else:
            etat = "%sECHEC %s" % (ROUGE, NEUTRE)
            total += 1
        print("  %-12s %s %s" % (nom, etat, note))
    print("\n%d reussies sur %d epreuves conclusives." % (reussis, total))
    return 0 if reussis == total else 1


if __name__ == "__main__":
    sys.exit(main())
