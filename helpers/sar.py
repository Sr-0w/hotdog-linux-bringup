#!/usr/bin/env python3
"""Diagnostic du capteur SAR SX9324.

Ecrit parce que le SAR a cesse de publier meme sa valeur initiale, ce qui est un
echec different de "pas de changement" et qui n'est pas explique. Le test guide
dit seulement s'il repond ; celui-ci dit ou il s'arrete.

Un capteur a evenement publie sa valeur courante des qu'un client s'abonne, sans
qu'aucune interruption n'intervienne. Il faut donc separer trois questions que
l'on confond facilement :

  1. le capteur est-il publie ?            -> a-t-il un SUID
  2. la demande est-elle acceptee ?        -> evenement de configuration 768,
                                              ou erreur 130
  3. emet-il une valeur, puis un changement ?

Seule la troisieme, et seulement sa deuxieme moitie, prouve que la puce a
signale et que le SLPI l'a recu.

Usage:
    sar.py            diagnostic complet, avec l'epreuve du geste
    sar.py --passif   sans geste : s'arrete apres la valeur initiale
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

MSG_SENSOR_CONFIG = 513
MSG_ON_CHANGE_CONFIG = 514
NOMS_EVENEMENT = {
    128: "attributs",
    130: "ERREUR",
    768: "configuration",
    1022: "etalonnage",
    1025: "echantillon",
}

VERT, ROUGE, JAUNE, GRAS, NEUTRE = (
    "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m")
if not sys.stdout.isatty():
    VERT = ROUGE = JAUNE = GRAS = NEUTRE = ""


def titre(texte):
    print("\n%s%s%s" % (GRAS, texte, NEUTRE))


def suid_de(type_donnee):
    try:
        sortie = subprocess.run(
            [sys.executable, str(CLIENT), type_donnee],
            capture_output=True, text=True, timeout=25).stdout
    except subprocess.TimeoutExpired:
        return None
    trouve = re.search(
        r"data-type '%s': ([0-9a-f]{32})" % re.escape(type_donnee), sortie)
    return trouve.group(1) if trouve else None


def decoder(donnees):
    """Rend (identifiants de message vus, vecteurs d'echantillon).

    L'identifiant est un fixed32 en champ 1, donc introduit par l'octet 0x0d.
    Un filtre plus lache attrape l'evenement d'etalonnage, dont le biais nul se
    lit comme un capteur mort.
    """
    ids, vecteurs = [], []
    pos = -1
    while True:
        pos = donnees.find(b"\x0d", pos + 1)
        if pos < 0 or pos + 5 > len(donnees):
            break
        mid = struct.unpack_from("<I", donnees, pos + 1)[0]
        if mid not in NOMS_EVENEMENT:
            continue
        ids.append(mid)
        if mid != 1025:
            continue
        tete = donnees.find(b"\x0a", pos)
        if not (0 < tete < pos + 40) or tete + 2 >= len(donnees):
            continue
        longueur = donnees[tete + 1]
        if 4 <= longueur <= 48 and longueur % 4 == 0 \
                and tete + 2 + longueur <= len(donnees):
            vecteurs.append(list(struct.unpack_from(
                "<%df" % (longueur // 4), donnees, tete + 2)))
    return ids, vecteurs


class Abonnement:
    def __init__(self, suid, msgid, rate=None):
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
        SSC.libc.setsockopt(self.fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                            struct.pack("qq", 0, 50000), 16)
        self.tampon = ctypes.create_string_buffer(4096)
        self.octets = 0

    def lire(self):
        ids, vecteurs = [], []
        for _ in range(48):
            recu = SSC.libc.recv(self.fd, self.tampon, 4096, 0)
            if recu <= 0:
                break
            self.octets += recu
            i, v = decoder(self.tampon.raw[:recu])
            ids.extend(i)
            vecteurs.extend(v)
        return ids, vecteurs

    def fermer(self):
        SSC.libc.close(self.fd)


def ecouter(suid, msgid, rate, secs, etiquette):
    """Abonne, ecoute, et rend ce qui est arrive."""
    ab = Abonnement(suid, msgid, rate)
    tous_ids, tous_vecteurs = [], []
    fin = time.time() + secs
    while time.time() < fin:
        ids, vecteurs = ab.lire()
        tous_ids.extend(ids)
        tous_vecteurs.extend(vecteurs)
        time.sleep(0.05)
    octets = ab.octets
    ab.fermer()
    vus = {}
    for i in tous_ids:
        vus[i] = vus.get(i, 0) + 1
    resume = ", ".join("%s x%d" % (NOMS_EVENEMENT[k], n)
                       for k, n in sorted(vus.items())) or "rien"
    print("  %-30s %4d octets  %s" % (etiquette, octets, resume))
    if tous_vecteurs:
        print("       premiere valeur: %s" %
              [round(x, 3) for x in tous_vecteurs[0][:4]])
    return tous_vecteurs, vus, octets


def registre(groupe, cles):
    chemin = pathlib.Path("/usr/share/qcom/sensors/registry") / groupe
    if not chemin.exists():
        return "(groupe absent)"
    try:
        import json
        d = json.loads(chemin.read_text())[groupe]
    except Exception:
        return "(illisible)"
    return "  ".join("%s=%s" % (c, d[c]["data"]) for c in cles if c in d)


def main():
    passif = "--passif" in sys.argv
    print("%sDiagnostic du SAR SX9324%s" % (GRAS, NEUTRE))

    titre("1. le capteur est-il publie ?")
    suid = suid_de("sars")
    if not suid:
        print("  %sNON%s  aucun SUID pour 'sars'." % (ROUGE, NEUTRE))
        print("       Le pilote ne s'est pas enregistre, ou il s'est retire.")
        print("       Un pilote SEE qui n'atteint pas sa puce supprime ses")
        print("       propres capteurs, donc l'absence de SUID est compatible")
        print("       avec un probe rate, pas seulement avec un enregistrement")
        print("       rate.")
        # un capteur voisin sert de temoin : si lui non plus n'est pas la,
        # c'est tout SEE qui est en cause, pas le SAR
        temoin = suid_de("accel")
        print("       temoin accel: %s" % (temoin or "absent aussi"))
        return 1
    print("  %sOUI%s  %s" % (VERT, NEUTRE, suid))

    titre("2. configuration servie")
    print("  plateforme : %s" % registre(
        "sx9324_op_0_platform.config",
        ["bus_type", "bus_instance", "slave_config", "dri_irq_num",
         "irq_is_chip_pin", "num_rail"]))

    titre("3. la demande est-elle acceptee, et emet-il une valeur ?")
    vecteurs, vus, _ = ecouter(suid, MSG_ON_CHANGE_CONFIG, None, 10,
                               "a evenement (514)")
    if 130 in vus:
        print("  %sLe SLPI refuse la demande (erreur 130).%s" % (ROUGE, NEUTRE))
        return 1
    if not vecteurs:
        print("  %sAucune valeur initiale.%s" % (ROUGE, NEUTRE))
        print("       C'est le point dur : un capteur a evenement doit publier")
        print("       sa valeur courante des l'abonnement, sans interruption.")
        print("       On reessaie en flux continu, qui n'emprunte pas le meme")
        print("       chemin dans le pilote.")
        vecteurs, vus, _ = ecouter(suid, MSG_SENSOR_CONFIG, 5.0, 10,
                                   "continu 5 Hz (513)")
        if not vecteurs:
            print("  %sMuet dans les deux modes.%s" % (ROUGE, NEUTRE))
            print("       A distinguer de la proximite malgre l'apparence :")
            print("       le SAR recoit un evenement de configuration, donc sa")
            print("       demande est acceptee ET honoree ; la proximite n'a")
            print("       jamais que l'accuse QMI. Le SAR va un cran plus loin")
            print("       dans le pilote avant de se taire.")
        else:
            print("  %sIl repond en continu mais pas a evenement.%s"
                  % (JAUNE, NEUTRE))

    base = vecteurs[0][:2] if vecteurs else None
    if base is not None:
        print("  %sValeur initiale publiee%s : %s"
              % (VERT, NEUTRE, [round(x, 3) for x in base]))

    if passif:
        print("\n  mode passif : on s'arrete avant l'epreuve du geste.")
        return 0 if base is not None else 1

    titre("4. change-t-il quand on le sollicite ? (temoin d'interruption)")
    print("  %s>> Posez la paume sur le bas du telephone, tenez trois"
          " secondes, puis retirez-la.%s" % (JAUNE, NEUTRE))
    ab = Abonnement(suid, MSG_ON_CHANGE_CONFIG, None)
    change = False
    dernier = base
    fin = time.time() + 25
    affiche = 0.0
    while time.time() < fin and not change:
        _, vecteurs = ab.lire()
        for v in vecteurs:
            dernier = v[:2]
            if base is None:
                # sans reference, le simple fait qu'un evenement apparaisse
                # sous la paume est deja la reponse cherchee
                change = True
                break
            if any(abs(v[i] - base[i]) > 0.5 for i in range(min(2, len(v)))):
                change = True
                break
        if time.time() - affiche > 1.0:
            print("     %-40s %2ds restantes\r" % (
                [round(x, 2) for x in dernier], int(fin - time.time())),
                end="", flush=True)
            affiche = time.time()
        time.sleep(0.05)
    ab.fermer()

    if change:
        quoi = ("un premier evenement est apparu sous la paume"
                if base is None else "changement detecte")
        print("  %sOK%s  %s : la puce a signale et le SLPI l'a recu.%s"
              % (VERT, NEUTRE, quoi, " " * 12))
        print("       Les interruptions capteur arrivent donc sur ce portage,")
        print("       et le silence de la proximite ne s'explique pas par leur")
        print("       absence.")
        return 0

    print("  %sECHEC%s  valeur initiale seule, aucun changement.%s"
          % (ROUGE, NEUTRE, " " * 20))
    print("       Le SAR est le seul capteur a evenement dont on puisse")
    print("       provoquer un changement a la main. S'il n'en signale jamais,")
    print("       aucune interruption capteur n'est remise au SLPI -- ce qui")
    print("       expliquerait la proximite, interrompue sur GPIO 117, sans")
    print("       rien invoquer de propre a sa puce.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
