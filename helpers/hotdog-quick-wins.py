#!/usr/bin/env python3

import fcntl
import glob
import os
import pathlib
import re
import select
import shlex
import struct
import subprocess
import sys
import time


LOG_DIR = pathlib.Path("/home/user")
STAMP = time.strftime("%Y%m%dT%H%M%S")
LOG_PATH = LOG_DIR / ("hotdog-quick-wins-%s.log" % STAMP)
ABS_SND_PROFILE = 0x22


def log(message=""):
    line = "[%s] %s" % (time.strftime("%F %T"), message)
    print(line, flush=True)
    with LOG_PATH.open("a", encoding="utf-8") as stream:
        stream.write(line + "\n")


def prompt(message):
    log(message)
    answer = input("> ").strip()
    log("reponse=%r" % answer)
    return answer


def yes(message):
    return prompt(message + " [o/N]").lower() in ("o", "oui", "y", "yes")


def run(command, check=False):
    display = " ".join(shlex.quote(part) for part in command)
    log("commande: " + display)
    result = subprocess.run(command, text=True, capture_output=True)
    if result.stdout:
        for line in result.stdout.rstrip().splitlines():
            log("stdout: " + line)
    if result.stderr:
        for line in result.stderr.rstrip().splitlines():
            log("stderr: " + line)
    log("rc=%d" % result.returncode)
    if check and result.returncode:
        raise RuntimeError("commande echouee: " + display)
    return result


def require_root():
    if os.geteuid() != 0:
        raise RuntimeError("relancer ce script avec sudo")


def find_input_device(name):
    text = pathlib.Path("/proc/bus/input/devices").read_text(
        encoding="utf-8", errors="replace"
    )
    for block in text.split("\n\n"):
        if ('N: Name="%s"' % name) not in block:
            continue
        for line in block.splitlines():
            if not line.startswith("H: Handlers="):
                continue
            for handler in line.split("=", 1)[1].split():
                if handler.startswith("event"):
                    return "/dev/input/" + handler
    return None


def _ioc(direction, kind, number, size):
    return (direction << 30) | (size << 16) | (kind << 8) | number


def read_abs(device, axis):
    # struct input_absinfo: value, minimum, maximum, fuzz, flat, resolution.
    payload = bytearray(struct.calcsize("iiiiii"))
    request = _ioc(2, ord("E"), 0x40 + axis, len(payload))
    with open(device, "rb", buffering=0) as stream:
        fcntl.ioctl(stream.fileno(), request, payload, True)
    return struct.unpack("iiiiii", payload)


def test_slider():
    device = find_input_device("Alert slider")
    if not device:
        log("SLIDER=BLOCKED: aucun input nomme 'Alert slider'")
        return

    log("slider_device=" + device)
    names = {0: "haut / silencieux", 1: "milieu / vibration",
             2: "bas / sonnerie"}
    current = read_abs(device, ABS_SND_PROFILE)[0]
    seen = set()
    if current in names:
        seen.add(current)
        log("slider initial=%d (%s)" % (current, names[current]))

    prompt("Le moniteur est pret. Appuie sur Entree, puis passe lentement par les trois positions. Il les affichera automatiquement.")
    log("Appuie sur Entree a nouveau seulement pour abandonner le test.")
    event_size = struct.calcsize("llHHi")
    with open(device, "rb", buffering=0) as stream:
        while seen != {0, 1, 2}:
            ready, unused_write, unused_error = select.select(
                [stream, sys.stdin], [], [], None
            )
            if sys.stdin in ready:
                sys.stdin.readline()
                log("SLIDER=INCOMPLETE seen=%s" % sorted(seen))
                return
            payload = stream.read(event_size * 16)
            for offset in range(0, len(payload) - event_size + 1, event_size):
                unused_sec, unused_usec, event_type, code, value = struct.unpack(
                    "llHHi", payload[offset:offset + event_size]
                )
                if event_type != 3 or code != ABS_SND_PROFILE:
                    continue
                if value not in names:
                    log("slider valeur inattendue=%d" % value)
                    continue
                seen.add(value)
                log("SLIDER_POSITION=PASS value=%d (%s) seen=%s" %
                    (value, names[value], sorted(seen)))

    log("SLIDER=PASS values=0,1,2")
    log("feedbackd doit appliquer silent, quiet et full respectivement.")


def wait_for_carrier(interface, wanted):
    path = pathlib.Path("/sys/class/net") / interface / "carrier"
    log("attente carrier %s=%d; aucune limite de temps" % (interface, wanted))
    while True:
        try:
            value = int(path.read_text().strip())
        except (FileNotFoundError, ValueError):
            value = 0
        if value == wanted:
            log("carrier %s=%d" % (interface, value))
            return
        time.sleep(1)


def ethernet_address(interface):
    result = run(["ip", "-4", "-o", "addr", "show", "dev", interface])
    return result.stdout.strip()


def ethernet_ping(interface):
    route = run(["ip", "route", "show", "dev", interface]).stdout
    target = ""
    for line in route.splitlines():
        fields = line.split()
        if "via" in fields:
            target = fields[fields.index("via") + 1]
            break
    if not target:
        target = prompt("Adresse IPv4 du routeur/peer a tester (vide = abandon):")
    if not target:
        log("ETHERNET_PING=BLOCKED: aucune cible")
        return False
    first = run(["ping", "-I", interface, "-c", "5", "-W", "2", target])
    sustained = run(["ping", "-I", interface, "-s", "1400", "-c", "100",
                     "-W", "2", target])
    passed = first.returncode == 0 and sustained.returncode == 0
    log("ETHERNET_TRAFFIC=%s target=%s" %
        ("PASS" if passed else "FAIL", target))
    return passed


def test_ethernet():
    require_root()
    prompt("Branche le dock USB-C et son cable Ethernet, puis appuie sur Entree.")
    while not pathlib.Path("/sys/class/net/eth0").exists():
        log("attente de eth0; aucune limite de temps")
        time.sleep(2)
    wait_for_carrier("eth0", 1)
    if not ethernet_address("eth0"):
        run(["udhcpc", "-i", "eth0", "-n", "-q"])
    log("eth0_address=" + ethernet_address("eth0"))
    first_pass = ethernet_ping("eth0")

    prompt("Debranche maintenant le dock, puis appuie sur Entree.")
    wait_for_carrier("eth0", 0)
    prompt("Rebranche le dock dans la meme orientation, puis appuie sur Entree.")
    wait_for_carrier("eth0", 1)
    if not ethernet_address("eth0"):
        run(["udhcpc", "-i", "eth0", "-n", "-q"])
    second_pass = ethernet_ping("eth0")
    log("ETHERNET=%s" % ("PASS" if first_pass and second_pass else "FAIL"))


def test_flashlight():
    require_root()
    leds = sorted(glob.glob("/sys/class/leds/*:torch"))
    if not leds:
        log("FLASHLIGHT=BLOCKED: aucune LED *:torch")
        return
    led = pathlib.Path(leds[0])
    brightness = led / "brightness"
    maximum = int((led / "max_brightness").read_text().strip())
    level = min(32, maximum)
    prompt("Regarde le flash arriere. Entree allumera la torche a faible puissance.")
    try:
        brightness.write_text("%d\n" % level)
        prompt("La torche doit etre allumee. Appuie sur Entree pour l'eteindre.")
    finally:
        brightness.write_text("0\n")
    visible = yes("La torche etait-elle visiblement allumee ?")
    menu = yes("Le bouton Lampe/Flashlight est-il visible et fonctionnel dans les reglages rapides Plasma ?")
    log("FLASHLIGHT=%s led=%s quick_setting=%s" %
        ("PASS" if visible and menu else "FAIL", led.name, menu))


def test_haptics_suspend():
    require_root()
    helper = "/home/user/hotdog-haptics-pulse"
    if not os.path.exists(helper):
        log("HAPTICS_SUSPEND=BLOCKED: helper absent")
        return
    device = find_input_device("Awinic AW8697 haptics")
    if not device:
        log("HAPTICS_SUSPEND=BLOCKED: input AW8697 absent")
        return
    run([helper, device, "50", "200"], check=True)
    before = yes("As-tu senti la vibration avant suspend ?")
    prompt("Entree suspendra le telephone 20 secondes. Il se reveillera seul.")
    result = run(["rtcwake", "-m", "mem", "-s", "20"])
    time.sleep(2)
    run([helper, device, "50", "200"])
    after = yes("As-tu senti la vibration apres le reveil ?")
    passed = result.returncode == 0 and before and after
    log("HAPTICS_SUSPEND=%s" % ("PASS" if passed else "FAIL"))


def test_nfc_tags():
    require_root()
    helper = "/usr/local/bin/hotdog-nfc-poll-mask"
    if not os.path.exists(helper):
        log("NFC_TAGS=BLOCKED: helper absent")
        return
    passed = True
    for number in (1, 2):
        label = prompt("Nom libre du tag NFC %d:" % number)
        prompt("Place %s sur le dos du telephone, puis appuie sur Entree." %
               (label or ("tag %d" % number)))
        result = run([helper, "0", "test", "reader", "12"])
        seen = yes("Le tag a-t-il ete detecte par l'interface utilisee ?")
        passed = passed and result.returncode == 0 and seen
    log("NFC_TAGS=%s" % ("PASS" if passed else "FAIL"))


def gpio_snapshot():
    values = {}
    text = pathlib.Path("/sys/kernel/debug/gpio").read_text(
        encoding="utf-8", errors="replace"
    )
    for line in text.splitlines():
        match = re.match(r"\s*gpio(\d+)\s*:.*\s(low|high)\s", line)
        if match:
            values[int(match.group(1))] = 1 if match.group(2) == "high" else 0
    return values


def test_slider_raw_gpios():
    require_root()
    snapshots = {}
    for label in ("haut", "milieu", "bas"):
        prompt("Place le slider en position %s, attends une seconde, puis appuie sur Entree." % label)
        time.sleep(1)
        snapshots[label] = gpio_snapshot()
        log("GPIO_SLIDER_%s gpio27=%s gpio125=%s gpio134=%s" %
            (label.upper(), snapshots[label].get(27),
             snapshots[label].get(125), snapshots[label].get(134)))

    changed = []
    all_lines = set().union(*(snapshot.keys() for snapshot in snapshots.values()))
    for line in sorted(all_lines):
        states = tuple(snapshots[label].get(line) for label in
                       ("haut", "milieu", "bas"))
        if len(set(states)) > 1:
            changed.append((line, states))
            log("GPIO_CHANGE line=%d top=%s middle=%s bottom=%s" %
                ((line,) + states))
    log("SLIDER_RAW_GPIO=%s changed=%s" %
        ("PASS" if changed else "NO_CHANGE", changed))


def main():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log("Hotdog quick wins - kernel=" + os.uname().release)
    log("log=" + str(LOG_PATH))
    tests = {
        "1": ("three-position slider", test_slider),
        "2": ("USB-C Ethernet", test_ethernet),
        "3": ("Plasma flashlight", test_flashlight),
        "4": ("haptics suspend/resume", test_haptics_suspend),
        "5": ("deux tags NFC", test_nfc_tags),
        "6": ("diagnostic brut des GPIO du slider", test_slider_raw_gpios),
    }
    while True:
        print("\nTests disponibles:")
        for key, (label, unused) in tests.items():
            print("  %s. %s" % (key, label))
        print("  q. quitter")
        choice = input("> ").strip().lower()
        if choice in ("q", "quit", "exit"):
            break
        if choice not in tests:
            print("Choix inconnu")
            continue
        label, function = tests[choice]
        log("DEBUT " + label)
        try:
            function()
        except (OSError, RuntimeError) as error:
            log("ERREUR %s: %s" % (label, error))
        log("FIN " + label)
    log("Termine. Conserve ce fichier pour analyse: " + str(LOG_PATH))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Interrompu par l'utilisateur")
        sys.exit(130)
