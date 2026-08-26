#!/usr/bin/env python3
"""Verifie la chaine complete : moteur ultrasonique -> IIO -> D-Bus.

Le probleme que ce script resout est qu'aucun bout ne se prouve seul. Le
moteur peut emettre sans que personne n'ecoute ; iio-sensor-proxy peut avoir
choisi le bon peripherique sans qu'on puisse le voir, parce que le pilote de
proximite IIO scrute -- il ouvre, lit et referme -- et ne tient donc jamais de
descripteur ouvert qu'on pourrait observer.

Alors on tient les deux bouts en meme temps : on arme le moteur, on reclame la
proximite sur D-Bus, et on journalise chaque changement des deux cotes avec le
meme horodatage. Un geste suffit ensuite a decider.

Usage:
    proximity-dbus-verify.py            120 secondes
    proximity-dbus-verify.py 60         duree choisie
"""
import os
import pathlib
import subprocess
import sys
import time

import gi
from gi.repository import Gio, GLib

HERE = pathlib.Path(__file__).resolve().parent
SMOKE = HERE / "elliptic-proximity-smoke.py"
if not SMOKE.exists():
    SMOKE = pathlib.Path("/home/user/elliptic-proximity-smoke.py")

JOURNAL = pathlib.Path("/home/user/prox-chaine.log")


def main():
    duree = float(sys.argv[1]) if len(sys.argv) > 1 else 120.0
    if not 0 < duree <= 300:
        sys.exit("duree hors de ]0, 300]")
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", sys.executable,
                           str(pathlib.Path(__file__).resolve()), str(duree)])

    journal = JOURNAL.open("w")

    def note(ligne):
        journal.write(ligne + "\n")
        journal.flush()
        print(ligne, flush=True)

    note("# verification de la chaine  %s" % time.strftime("%F %T"))

    # Le moteur ne parle que si le chemin audio ultrason est arme, et l'armer
    # est une action d'espace utilisateur. Sans lui, in_proximity_raw refuse.
    moteur = subprocess.Popen(
        [sys.executable, str(SMOKE), "--record", str(int(duree) + 10),
         "--log", "/home/user/prox-chaine-moteur.log"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(6)

    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    proxy = Gio.DBusProxy.new_sync(
        bus, Gio.DBusProxyFlags.NONE, None, "net.hadess.SensorProxy",
        "/net/hadess/SensorProxy", "net.hadess.SensorProxy", None)
    proxy.call_sync("ClaimProximity", None, Gio.DBusCallFlags.NONE, -1, None)
    note("reclamation tenue ; HasProximity=%s ProximityNear=%s"
         % (proxy.get_cached_property("HasProximity"),
            proxy.get_cached_property("ProximityNear")))

    depart = time.monotonic()
    loop = GLib.MainLoop()

    def change(_proxy, changed, _invalidated):
        if "ProximityNear" in changed.keys():
            note("t=%7.2f  D-Bus ProximityNear=%s"
                 % (time.monotonic() - depart,
                    changed["ProximityNear"]))

    proxy.connect("g-properties-changed", change)

    def fin():
        loop.quit()
        return False

    GLib.timeout_add_seconds(int(duree), fin)
    print("\n\033[33m>> Portez le telephone a l'oreille cinq secondes, puis")
    print("   eloignez-le cinq secondes. Repetez pendant %d s.\033[0m\n" % duree)
    loop.run()

    proxy.call_sync("ReleaseProximity", None, Gio.DBusCallFlags.NONE, -1, None)
    moteur.terminate()
    moteur.wait(timeout=20)
    note("# fin")
    journal.close()
    print("\nJournal : %s" % JOURNAL)
    print("Journal moteur : /home/user/prox-chaine-moteur.log")
    return 0


if __name__ == "__main__":
    sys.exit(main())
