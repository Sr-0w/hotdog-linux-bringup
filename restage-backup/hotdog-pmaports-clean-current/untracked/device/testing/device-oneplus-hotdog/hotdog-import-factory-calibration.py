#!/usr/bin/env python3
"""Importe l'etalonnage d'usine depuis la partition persist de l'appareil.

Pourquoi il faut le faire, et pourquoi il ne faut pas livrer de valeurs
-----------------------------------------------------------------------
Les capteurs sont etalonnes en usine, exemplaire par exemplaire, et le resultat
est ecrit dans `persist`, que `sns_reg.conf` designe :

    file=output=/mnt/vendor/persist/sensors/registry/registry

Cette partition survit au deverrouillage et aux flashs : chaque telephone porte
donc encore ses propres valeurs. Les copier d'un appareil a un autre donnerait a
tout le monde l'etalonnage d'un seul, ce qui est pire que pas d'etalonnage du
tout -- un biais faux est applique avec confiance, alors qu'un biais nul est au
moins neutre.

Ce que le script importe, et ce qu'il laisse
--------------------------------------------
Uniquement les valeurs marquees mesurees. Le champ `ver` du registre distingue
une valeur ecrite par l'usine, `ver` non nul, d'un defaut regenere par le
parseur, `ver` a "0". On ne recopie donc pas des groupes entiers : le registre
d'usine vient d'OxygenOS et contient aussi de la configuration que ce portage
modifie deliberement.

Concretement, sur l'exemplaire de developpement, sans cet import :

    lsm6dsm accel bias    0.000000        au lieu de  -0.086188, 0.213099, 0.035143
    tcs3701 als scale  1000.000000        au lieu de  1156.547607

soit un accelerometre non compense et une echelle de luminosite fausse d'environ
quinze pour cent.

La partition est montee en lecture seule et n'est jamais ecrite.

Usage:
    hotdog-import-factory-calibration.py            applique
    hotdog-import-factory-calibration.py --essai    montre sans rien ecrire
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

SERVI = pathlib.Path("/usr/share/qcom/sensors/registry")
PARTITION = pathlib.Path("/dev/disk/by-partlabel/persist")
SOUS_CHEMIN = "sensors/registry/registry"


def monter_persist():
    """Monte persist en lecture seule et rend (point de montage, a_demonter)."""
    for deja in ("/mnt/vendor/persist", "/mnt/persist", "/persist"):
        candidat = pathlib.Path(deja) / SOUS_CHEMIN
        if candidat.is_dir():
            return pathlib.Path(deja), False
    if not PARTITION.exists():
        sys.exit("partition persist introuvable : %s" % PARTITION)
    point = pathlib.Path(tempfile.mkdtemp(prefix="persist-ro-"))
    reel = os.path.realpath(PARTITION)
    res = subprocess.run(["mount", "-o", "ro", reel, str(point)],
                         capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit("montage impossible: %s" % res.stderr.strip())
    return point, True


def valeurs(chemin):
    """Rend {cle: (ver, data)} pour un fichier de groupe, ou None."""
    try:
        contenu = json.loads(chemin.read_text())
    except Exception:
        return None
    if len(contenu) != 1:
        return None
    groupe = next(iter(contenu))
    entrees = contenu[groupe]
    if not isinstance(entrees, dict):
        return None
    return groupe, entrees


def main():
    essai = "--essai" in sys.argv
    point, a_demonter = monter_persist()
    usine = point / SOUS_CHEMIN
    try:
        if not usine.is_dir():
            sys.exit("registre d'usine absent sous %s" % usine)
        print("registre d'usine : %s (%d fichiers)"
              % (usine, len(list(usine.iterdir()))))
        print("registre servi   : %s" % SERVI)
        print()

        modifies = 0
        for fichier in sorted(usine.iterdir()):
            cible = SERVI / fichier.name
            if not fichier.is_file() or not cible.exists():
                continue
            src = valeurs(fichier)
            dst = valeurs(cible)
            if not src or not dst:
                continue
            groupe_src, entrees_src = src
            groupe_dst, entrees_dst = dst
            if groupe_src != groupe_dst:
                continue

            a_ecrire = {}
            for cle, v in entrees_src.items():
                if cle == "owner" or not isinstance(v, dict):
                    continue
                # seul le marqueur "mesure" autorise la recopie
                if v.get("ver", "0") == "0":
                    continue
                # les entrees de type groupe ne portent pas de valeur : les
                # comparer ne veut rien dire et les recopier ne fait rien
                if v.get("type") == "grp":
                    continue
                w = entrees_dst.get(cle)
                if not isinstance(w, dict):
                    continue
                # seule une donnee differente justifie d'ecrire. Un `ver` plus
                # eleve cote servi signifie que le SLPI a reetalonne depuis
                # l'usine : le rabaisser detruirait un resultat plus recent
                # pour une valeur identique.
                if w.get("data") == v.get("data"):
                    continue
                a_ecrire[cle] = v

            if not a_ecrire:
                continue

            print("%s" % fichier.name)
            for cle, v in sorted(a_ecrire.items()):
                avant = entrees_dst.get(cle, {})
                print("    %-12s %s (ver %s)  ->  %s (ver %s)"
                      % (cle, avant.get("data"), avant.get("ver"),
                         v.get("data"), v.get("ver")))
            modifies += 1

            if essai:
                continue

            sauvegarde = cible.with_name(cible.name + ".avant-import-usine")
            if not sauvegarde.exists():
                shutil.copy2(cible, sauvegarde)
            info = cible.stat()
            contenu = json.loads(cible.read_text())
            for cle, v in a_ecrire.items():
                contenu[groupe_dst][cle] = v
            cible.write_text(json.dumps(contenu, separators=(",", ":")))
            # le SLPI reecrit ce registre : il doit rester a lui
            os.chown(cible, info.st_uid, info.st_gid)
            os.chmod(cible, info.st_mode & 0o7777)

        print()
        if modifies == 0:
            print("rien a importer : l'etalonnage servi correspond deja a l'usine.")
        elif essai:
            print("%d groupe(s) seraient modifie(s). Relancer sans --essai."
                  % modifies)
        else:
            print("%d groupe(s) importes. Redemarrer pour que le SLPI les relise."
                  % modifies)
        return 0
    finally:
        if a_demonter:
            subprocess.run(["umount", str(point)], capture_output=True)
            try:
                point.rmdir()
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
