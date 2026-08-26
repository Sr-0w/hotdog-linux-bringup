#!/usr/bin/env python3
"""Bounded smoke test for the OnePlus Elliptic ultrasonic proximity path."""

import argparse
import importlib.util
import ctypes
import os
import pathlib
import re
import select
import shutil
import struct
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
MODULE = HERE / "hotdog-ultrasound.py"
if not MODULE.exists():
    MODULE = pathlib.Path("/usr/libexec/hotdog-ultrasound.py")

_spec = importlib.util.spec_from_file_location("hotdog_ultrasound", MODULE)
U = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(U)

# Liaisons explicites plutot qu'une injection dans l'espace de noms : on voit
# d'un coup d'oeil ce qui vient du module partage.
SmokeError = U.SmokeError
AlsaHostless = U.AlsaHostless
parse_pcm_devices = U.parse_pcm_devices
find_pcm = U.find_pcm
one_path = U.one_path
find_driver_enable = U.find_driver_enable
run_checked = U.run_checked
read_control = U.read_control
set_control = U.set_control
PCM_CAPTURE_NAME = U.PCM_CAPTURE_NAME
PCM_PLAYBACK_NAME = U.PCM_PLAYBACK_NAME
MIXER_CONTROL = U.MIXER_CONTROL
MIC_CONTROLS = U.MIC_CONTROLS
PROXIMITY_MODE = U.PROXIMITY_MODE


INPUT_EVENT = struct.Struct("llHHi")
EV_MSC = 0x04
MSC_RAW = 0x03

INPUT_NAME = "Elliptic ultrasonic proximity"
STATE_FILE = pathlib.Path("/run/hotdog-proximity")

MICROPHONE_INDEX_MAX = 7

# The engine confirms near quickly and far over a longer stable window, so a
# symmetric 15 s gate failed the uncover half of every guided cycle while the
# events themselves were arriving correctly.
GESTURE_TIMEOUT = 30.0

SND_PCM_FORMAT_S16_LE = 2


def find_input_event():
    matches = []
    for event in pathlib.Path("/sys/class/input").glob("event*"):
        name = event / "device" / "name"
        try:
            if name.read_text().strip() == INPUT_NAME:
                matches.append(pathlib.Path("/dev/input") / event.name)
        except OSError:
            continue
    return one_path(matches, "Elliptic input event device")


def log_line(output, line):
    print(line, flush=True)
    if output:
        output.write(line + "\n")
        output.flush()


def read_proximity_event(event_file, timeout, output):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([event_file], [], [], 0.5)
        if not ready:
            continue
        data = event_file.read(INPUT_EVENT.size)
        if len(data) != INPUT_EVENT.size:
            raise SmokeError("short input event")
        _, _, event_type, code, value = INPUT_EVENT.unpack(data)
        if event_type != EV_MSC or code != MSC_RAW:
            continue
        state = "near" if value else "far"
        STATE_FILE.write_text(state + "\n")
        log_line(output, "%s %s" % (time.strftime("%F %T"), state))
        return state
    return None


def wait_for_state(event_file, expected, timeout, output):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = read_proximity_event(
            event_file, min(0.5, deadline - time.monotonic()), output)
        if state == expected:
            return True
    return False


def smoke(duration, log_path=None, interactive=False, electronic_probe=False,
          operation_mode=PROXIMITY_MODE, microphone_index=0, record=None):
    if os.geteuid() != 0:
        raise SmokeError("run this smoke test as root")

    release = os.uname().release
    if release != "6.16.0-sm8150":
        raise SmokeError("unexpected kernel release: %s" % release)

    devices = parse_pcm_devices(pathlib.Path("/proc/asound/pcm").read_text())
    playback = find_pcm(devices, PCM_PLAYBACK_NAME, "playback")
    capture = find_pcm(devices, PCM_CAPTURE_NAME, "capture")
    if playback["card"] != capture["card"]:
        raise SmokeError("hostless PCMs belong to different sound cards")

    card = playback["card"]
    enable = find_driver_enable()
    rx_port = enable.parent / "rx_port"
    if not rx_port.exists():
        raise SmokeError("missing Elliptic RX port control")
    mode_control = enable.parent / "operation_mode"
    if not mode_control.exists():
        raise SmokeError("missing Elliptic operation mode control")
    ramp_down = enable.parent / "ramp_down"
    if not ramp_down.exists():
        raise SmokeError("missing Elliptic ramp-down control")
    # Older builds of the driver have no such control. They are still usable
    # for everything else, so only refuse when a channel was actually asked
    # for -- silently running on the DSP default is what hid this for days.
    mic_control = enable.parent / "microphone_index"
    if not mic_control.exists():
        if microphone_index is not None:
            raise SmokeError(
                "driver has no microphone_index control; rebuild it or pass "
                "--microphone-index none")
        mic_control = None
    event_path = find_input_event()
    output = open(log_path, "a") if log_path else None
    hostless = None
    armed = False
    rx_armed = False
    control_prestates = []
    events = 0
    mode_prestate = mode_control.read_text().strip()
    mic_prestate = mic_control.read_text().strip() if mic_control else None

    try:
        log_line(output, "kernel=%s card=%d playback=%d capture=%d event=%s mode=%d"
                 % (release, card, playback["device"], capture["device"],
                    event_path, operation_mode))
        if interactive:
            print("\nTest de proximite ultrasonique Elliptic", flush=True)
            print("Pose le telephone face vers toi, sans rien devant le haut "
                  "de l'ecran.", flush=True)
            input("Quand le capteur est bien DECOUVERT, appuie sur Entree... ")

        # OxygenOS enables the Elliptic engine before opening its hostless
        # TX/RX PCMs. Some firmware revisions do not begin processing when
        # that order is reversed.
        mode_control.write_text("%d\n" % operation_mode)
        if mic_control and microphone_index is not None:
            mic_control.write_text("%d\n" % microphone_index)
            log_line(output, "microphone-index %d" % microphone_index)
        enable.write_text("1\n")
        armed = True

        controls = ((MIXER_CONTROL, "1"),) + MIC_CONTROLS
        for name, value in controls:
            control_prestates.append((name, read_control(card, name)))
            set_control(card, name, value)
        rx_port.write_text("1\n")
        rx_armed = True
        hostless = AlsaHostless()
        hostless.start(card, playback["device"], capture["device"])
        event_stats = enable.parent / "event_stats"
        if event_stats.exists():
            log_line(output, "event-stats-armed: %s"
                     % event_stats.read_text().strip())

        with event_path.open("rb", buffering=0) as event_file:
            if interactive:
                for cycle in range(1, 4):
                    print("\nCycle %d/3" % cycle, flush=True)
                    input("COUVRE maintenant le haut de l'ecran, puis appuie "
                          "sur Entree... ")
                    if not wait_for_state(event_file, "near",
                                          GESTURE_TIMEOUT, output):
                        raise SmokeError("no near event after cover gesture "
                                         "in cycle %d" % cycle)
                    events += 1
                    print("Near recu.", flush=True)

                    input("DECOUVRE completement le haut de l'ecran, puis "
                          "appuie sur Entree... ")
                    if not wait_for_state(event_file, "far",
                                          GESTURE_TIMEOUT, output):
                        raise SmokeError("no far event after uncover gesture "
                                         "in cycle %d" % cycle)
                    events += 1
                    print("Far recu.", flush=True)
            elif record:
                # Measure rather than gate. Every transition is timestamped
                # against the moment the engine was armed, so near and far
                # latency can be read off the log instead of guessed at.
                log_line(output, "record: %.0fs" % record)
                started = time.monotonic()
                deadline = started + record
                remaining = -1
                while time.monotonic() < deadline:
                    state = read_proximity_event(event_file, 0.5, output)
                    if state:
                        events += 1
                        log_line(output, "t=%7.2f %s"
                                 % (time.monotonic() - started, state))
                    left = int(deadline - time.monotonic()) + 1
                    if left != remaining:
                        print("\r  %3ds  %d transitions   "
                              % (left, events), end="", flush=True)
                        remaining = left
                print()
                log_line(output, "record-total: %d transitions" % events)
            elif electronic_probe:
                log_line(output, "electronic-probe: covered warmup")
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if read_proximity_event(event_file, 0.5, output):
                        events += 1

                log_line(output, "electronic-probe: transducer off")
                set_control(card, MIXER_CONTROL, "0")
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if read_proximity_event(event_file, 0.5, output):
                        events += 1

                log_line(output, "electronic-probe: transducer on")
                set_control(card, MIXER_CONTROL, "1")
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    if read_proximity_event(event_file, 0.5, output):
                        events += 1
            else:
                deadline = time.monotonic() + duration
                while time.monotonic() < deadline:
                    if read_proximity_event(event_file, 0.5, output):
                        events += 1
    finally:
        event_stats = enable.parent / "event_stats"
        if event_stats.exists():
            try:
                log_line(output, "event-stats-final: %s"
                         % event_stats.read_text().strip())
            except OSError as error:
                log_line(output, "ERROR event stats: %s" % error)
        if armed:
            try:
                ramp_down.write_text("1\n")
                time.sleep(0.02)
            except OSError as error:
                log_line(output, "ERROR ramp down: %s" % error)
        if hostless:
            hostless.close()
        for name, value in reversed(control_prestates):
            try:
                set_control(card, name, value)
            except (OSError, subprocess.CalledProcessError) as error:
                log_line(output, "ERROR mixer rollback %s: %s"
                         % (name, error))
        if rx_armed:
            try:
                rx_port.write_text("0\n")
            except OSError as error:
                log_line(output, "ERROR RX port disable: %s" % error)
        if armed:
            try:
                enable.write_text("0\n")
            except OSError as error:
                log_line(output, "ERROR disable: %s" % error)
        try:
            mode_control.write_text(mode_prestate + "\n")
        except OSError as error:
            log_line(output, "ERROR mode rollback: %s" % error)
        if mic_control and mic_prestate is not None:
            try:
                mic_control.write_text(mic_prestate + "\n")
            except OSError as error:
                log_line(output, "ERROR microphone-index rollback: %s" % error)
        STATE_FILE.write_text("unknown\n")
        if output:
            output.close()

    if not events:
        raise SmokeError("no proximity event received during the bounded run")
    return 0


def sweep(args):
    """Try every microphone channel, one bounded run each.

    Only worth running if channel 0 -- the value OxygenOS writes -- produces
    nothing. Each run arms and rolls back on its own, so a failure on one
    channel leaves nothing behind for the next.
    """
    print("Couvrez et decouvrez le haut du telephone sans vous arreter")
    print("pendant tout le balayage. Journal: %s\n" % args.log)
    found = []
    for index in range(MICROPHONE_INDEX_MAX + 1):
        print("  canal %d ... " % index, end="", flush=True)
        try:
            smoke(args.duration, args.log, False, False,
                  args.operation_mode, index)
        except (OSError, SmokeError, subprocess.CalledProcessError) as error:
            print("rien (%s)" % error)
            continue
        print("EVENEMENT RECU")
        found.append(index)
    if not found:
        print("\nAucun canal n'a produit le parametre 16.")
        return 1
    print("\nCanaux ayant produit un evenement: %s"
          % ", ".join(str(i) for i in found))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=60.0)
    parser.add_argument("--log", type=pathlib.Path)
    parser.add_argument("--operation-mode", type=int, choices=(693, PROXIMITY_MODE),
                        default=PROXIMITY_MODE)
    parser.add_argument("--microphone-index", default="0",
                        help="channel the engine listens on; stock uses 0. "
                             "'none' leaves the DSP on its own default, which "
                             "is what every run before this one did.")
    parser.add_argument("--sweep-microphone", action="store_true",
                        help="try each channel in turn, keeping the engine "
                             "down between runs. Cover and uncover the top of "
                             "the phone continuously for the whole sweep.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--interactive", action="store_true", dest="interactive")
    mode.add_argument("--monitor", action="store_false", dest="interactive")
    mode.add_argument("--electronic-probe", action="store_true")
    mode.add_argument("--record", type=float, metavar="SECONDS",
                      help="arm the engine and timestamp every transition for "
                           "this long. Cover and uncover at your own pace; "
                           "nothing has to line up with a prompt.")
    parser.set_defaults(interactive=True)
    args = parser.parse_args(argv)
    if args.duration <= 0 or args.duration > 300:
        parser.error("duration must be in ]0, 300] seconds")
    if args.microphone_index == "none":
        args.microphone_index = None
    else:
        try:
            args.microphone_index = int(args.microphone_index, 0)
        except ValueError:
            parser.error("--microphone-index takes an integer or 'none'")
        if not 0 <= args.microphone_index <= MICROPHONE_INDEX_MAX:
            parser.error("--microphone-index must be in [0, %d]"
                         % MICROPHONE_INDEX_MAX)
    if args.sweep_microphone:
        args.interactive = False
    if args.electronic_probe:
        args.interactive = False
    if args.record is not None:
        if not 0 < args.record <= 300:
            parser.error("--record must be in ]0, 300] seconds")
        args.interactive = False
    if (args.interactive or args.sweep_microphone
            or args.record is not None) and args.log is None:
        args.log = pathlib.Path("/home/user/proximity-test-%s.log"
                                % time.strftime("%Y%m%d-%H%M%S"))
    if (args.interactive or args.sweep_microphone
            or args.record is not None) and os.geteuid() != 0:
        # This image ships sudo and no doas. Try both rather than failing on
        # the one that happens to be absent.
        elevate = next((tool for tool in ("doas", "sudo")
                        if shutil.which(tool)), None)
        if elevate is None:
            print("ERROR: run this as root; neither doas nor sudo is present",
                  file=sys.stderr)
            return 1
        command = [elevate, sys.executable,
                   str(pathlib.Path(__file__).resolve())]
        command.extend(sys.argv[1:])
        os.execvp(command[0], command)
    if args.sweep_microphone:
        return sweep(args)
    try:
        result = smoke(args.duration, args.log, args.interactive,
                       args.electronic_probe, args.operation_mode,
                       args.microphone_index, args.record)
        if args.interactive:
            print("\nPASS: trois cycles near/far recus.")
            print("Journal: %s" % args.log)
        elif args.record is not None:
            print("Journal: %s" % args.log)
        return result
    except (OSError, SmokeError, subprocess.CalledProcessError) as error:
        print("ERROR: %s" % error, file=sys.stderr)
        if args.log:
            with args.log.open("a") as output:
                output.write("ERROR: %s\n" % error)
            print("Journal: %s" % args.log, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
