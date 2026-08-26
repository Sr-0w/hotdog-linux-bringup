#!/usr/bin/env python3
"""Arme le chemin audio ultrason tant que quelqu'un lit la proximite.

Le moteur Elliptic ne parle que si son chemin audio est monte, et le monter
demande d'ouvrir deux PCM sans hote et de poser une route mixer -- du travail
d'espace utilisateur, qu'un pilote noyau ne peut pas faire seul. Sans ce
service, le capteur fonctionne mais reste muet en usage normal : personne ne
l'arme.

Le declencheur est le pilote lui-meme. Il expose `demand`, qui vaut 1 tant que
`in_proximity_raw` a ete lu recemment. Un consommateur qui reclame la
proximite se met a la scruter -- iio-sensor-proxy toutes les 700 ms -- et c'est
exactement le signal qu'il faut. On arme quand la demande apparait, on desarme
quand elle retombe.

C'est aussi la forme qu'a OxygenOS : sa HAL capteurs demande a la HAL audio de
monter le chemin, elle ne le monte pas elle-meme.
"""
import importlib.util
import os
import pathlib
import signal
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
MODULE = HERE / "hotdog-ultrasound.py"
if not MODULE.exists():
    MODULE = pathlib.Path("/usr/libexec/hotdog-ultrasound.py")

_spec = importlib.util.spec_from_file_location("hotdog_ultrasound", MODULE)
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

JOURNAL = pathlib.Path("/var/log/hotdog-proximity-arm.log")
INTERVALLE = 1.0
# Le consommateur scrute a 700 ms ; il faut plus que ca avant de conclure au
# desinteret, sinon un cycle manque desarme le chemin sous ses pieds.
GRACE = 5.0


class Chemin:
    """Le chemin audio ultrason, monte ou demonte d'un bloc."""

    def __init__(self, journal):
        self.j = journal
        self.arme = False
        self.hostless = None
        self.prestates = []
        self.rx = False

        devices = S.parse_pcm_devices(
            pathlib.Path("/proc/asound/pcm").read_text())
        self.playback = S.find_pcm(devices, S.PCM_PLAYBACK_NAME, "playback")
        self.capture = S.find_pcm(devices, S.PCM_CAPTURE_NAME, "capture")
        if self.playback["card"] != self.capture["card"]:
            raise S.SmokeError("les PCM sans hote sont sur deux cartes")
        self.card = self.playback["card"]

        self.enable = S.find_driver_enable()
        base = self.enable.parent
        self.rx_port = base / "rx_port"
        self.mode = base / "operation_mode"
        self.ramp_down = base / "ramp_down"
        self.mic = base / "microphone_index"
        self.demand = base / "demand"
        for chemin in (self.rx_port, self.mode, self.ramp_down, self.demand):
            if not chemin.exists():
                raise S.SmokeError("controle absent: %s" % chemin.name)

    def note(self, ligne):
        self.j.write("%s %s\n" % (time.strftime("%F %T"), ligne))
        self.j.flush()

    def demande(self):
        try:
            return self.demand.read_text().strip() == "1"
        except OSError:
            return False

    def monter(self):
        if self.arme:
            return
        # OxygenOS active le moteur avant d'ouvrir ses PCM ; certaines
        # revisions du firmware ne demarrent pas dans l'ordre inverse.
        self.mode.write_text("%d\n" % S.PROXIMITY_MODE)
        if self.mic.exists():
            self.mic.write_text("0\n")
        self.enable.write_text("1\n")
        self.arme = True
        for nom, valeur in ((S.MIXER_CONTROL, "1"),) + S.MIC_CONTROLS:
            self.prestates.append((nom, S.read_control(self.card, nom)))
            S.set_control(self.card, nom, valeur)
        self.rx_port.write_text("1\n")
        self.rx = True
        self.hostless = S.AlsaHostless()
        self.hostless.start(self.card, self.playback["device"],
                            self.capture["device"])
        self.note("arme")

    def demonter(self):
        """Demonte dans l'ordre inverse exact, sans jamais lever."""
        if not self.arme and not self.hostless:
            return
        try:
            self.ramp_down.write_text("1\n")
            time.sleep(0.02)
        except OSError as e:
            self.note("ERREUR rampe: %s" % e)
        if self.hostless:
            try:
                self.hostless.close()
            except Exception as e:                         # noqa: BLE001
                self.note("ERREUR fermeture PCM: %s" % e)
            self.hostless = None
        for nom, valeur in reversed(self.prestates):
            try:
                S.set_control(self.card, nom, valeur)
            except Exception as e:                         # noqa: BLE001
                self.note("ERREUR restauration %s: %s" % (nom, e))
        self.prestates = []
        if self.rx:
            try:
                self.rx_port.write_text("0\n")
            except OSError as e:
                self.note("ERREUR port RX: %s" % e)
            self.rx = False
        try:
            self.enable.write_text("0\n")
        except OSError as e:
            self.note("ERREUR desactivation: %s" % e)
        self.arme = False
        self.note("desarme")


def main():
    if os.geteuid() != 0:
        sys.exit("ce service doit tourner en root")
    journal = JOURNAL.open("a")
    chemin = Chemin(journal)
    chemin.note("demarre; demande=%s" % chemin.demande())

    fini = {"oui": False}

    def arreter(signum, frame):
        fini["oui"] = True

    signal.signal(signal.SIGTERM, arreter)
    signal.signal(signal.SIGINT, arreter)

    derniere_demande = 0.0
    try:
        while not fini["oui"]:
            if chemin.demande():
                derniere_demande = time.monotonic()
                if not chemin.arme:
                    try:
                        chemin.monter()
                    except Exception as e:                 # noqa: BLE001
                        chemin.note("ERREUR montage: %s" % e)
                        chemin.demonter()
            elif chemin.arme and \
                    time.monotonic() - derniere_demande > GRACE:
                chemin.demonter()
            time.sleep(INTERVALLE)
    finally:
        chemin.demonter()
        chemin.note("arrete")
        journal.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
