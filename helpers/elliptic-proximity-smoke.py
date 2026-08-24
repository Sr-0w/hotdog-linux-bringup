#!/usr/bin/env python3
"""Bounded smoke test for the OnePlus Elliptic ultrasonic proximity path."""

import argparse
import ctypes
import os
import pathlib
import re
import select
import struct
import subprocess
import sys
import time


INPUT_EVENT = struct.Struct("llHHi")
EV_MSC = 0x04
MSC_RAW = 0x03

PCM_CAPTURE_NAME = "SLIMBUS2_HOSTLESS Capture"
PCM_PLAYBACK_NAME = "Quaternary MI2S_RX Hostless Playback"
MIXER_CONTROL = "QUAT_MI2S_RX Audio Mixer Ultrasound"
MIC_CONTROLS = (
    ("AIF2_CAP Mixer SLIM TX2", "1"),
    ("CDC_IF TX2 MUX", "DEC2"),
    ("ADC MUX2", "AMIC"),
    ("AMIC MUX2", "ADC3"),
    ("ADC3 Volume", "12"),
)
INPUT_NAME = "Elliptic ultrasonic proximity"
STATE_FILE = pathlib.Path("/run/hotdog-proximity")

SND_PCM_STREAM_PLAYBACK = 0
SND_PCM_STREAM_CAPTURE = 1
SND_PCM_FORMAT_S16_LE = 2
SND_PCM_ACCESS_RW_INTERLEAVED = 3
SND_PCM_STATE_RUNNING = 3


class SmokeError(RuntimeError):
    pass


def parse_pcm_devices(text):
    devices = []
    pattern = re.compile(r"^(\d+)-(\d+):\s*([^:]+?)\s*:\s*(.*)$")
    for line in text.splitlines():
        match = pattern.match(line.strip())
        if not match:
            continue
        card, device, name, capabilities = match.groups()
        name = re.sub(r"\s+\(\*\)$", "", name.strip())
        devices.append({
            "card": int(card),
            "device": int(device),
            "name": name,
            "playback": "playback" in capabilities,
            "capture": "capture" in capabilities,
        })
    return devices


def find_pcm(devices, name, direction):
    matches = [item for item in devices
               if item["name"] == name and item[direction]]
    if len(matches) != 1:
        raise SmokeError("expected exactly one %s PCM named %r, found %d"
                         % (direction, name, len(matches)))
    return matches[0]


def one_path(paths, description):
    matches = [path for path in paths if path.exists()]
    if len(matches) != 1:
        raise SmokeError("expected exactly one %s, found %d"
                         % (description, len(matches)))
    return matches[0]


def find_driver_enable():
    root = pathlib.Path("/sys/bus/platform/drivers/q6-elliptic-ultrasound")
    return one_path(root.glob("*/enable"), "Elliptic enable control")


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


def run_checked(command):
    return subprocess.run(command, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True).stdout


def read_control(card, name):
    output = run_checked([
        "amixer", "-c", str(card), "cget", "name=%s" % name,
    ])
    matches = re.findall(r"^\s*: values=(.+)$", output, re.MULTILINE)
    if len(matches) != 1 or "," in matches[0]:
        raise SmokeError("cannot preserve mixer control %r" % name)
    return matches[0].strip()


def set_control(card, name, value):
    run_checked([
        "amixer", "-q", "-c", str(card), "cset", "name=%s" % name,
        str(value),
    ])


class AlsaHostless:
    def __init__(self):
        self.lib = ctypes.CDLL("libasound.so.2")
        self.lib.snd_strerror.restype = ctypes.c_char_p
        self.handles = []

    def check(self, operation, result):
        if result < 0:
            detail = self.lib.snd_strerror(result).decode(errors="replace")
            raise SmokeError("%s failed: %s" % (operation, detail))

    def open_pcm(self, name, stream, start_threshold=None):
        handle = ctypes.c_void_p()
        self.check("open %s" % name, self.lib.snd_pcm_open(
            ctypes.byref(handle), name.encode(), stream, 0))
        self.handles.append(handle)
        self.check("configure %s" % name, self.lib.snd_pcm_set_params(
            handle, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
            1, 48000, 0, 500000))
        if start_threshold is not None:
            params = ctypes.c_void_p()
            self.check("allocate software parameters",
                       self.lib.snd_pcm_sw_params_malloc(ctypes.byref(params)))
            try:
                self.check("read software parameters",
                           self.lib.snd_pcm_sw_params_current(handle, params))
                self.check("set start threshold",
                           self.lib.snd_pcm_sw_params_set_start_threshold(
                               handle, params, start_threshold))
                self.check("apply software parameters",
                           self.lib.snd_pcm_sw_params(handle, params))
            finally:
                self.lib.snd_pcm_sw_params_free(params)
        self.check("prepare %s" % name, self.lib.snd_pcm_prepare(handle))
        return handle

    def start(self, card, playback, capture):
        playback_name = "hw:%d,%d" % (card, playback)
        capture_name = "hw:%d,%d" % (card, capture)
        playback_handle = self.open_pcm(
            playback_name, SND_PCM_STREAM_PLAYBACK, start_threshold=1)
        capture_handle = self.open_pcm(capture_name, SND_PCM_STREAM_CAPTURE)
        self.check("start %s" % capture_name,
                   self.lib.snd_pcm_start(capture_handle))
        sample = (ctypes.c_int16 * 1)(0)
        result = self.lib.snd_pcm_writei(playback_handle, sample, 1)
        self.check("prime %s" % playback_name, result)
        if result != 1:
            raise SmokeError("short hostless playback prime")
        for handle in (playback_handle, capture_handle):
            if self.lib.snd_pcm_state(handle) != SND_PCM_STATE_RUNNING:
                raise SmokeError("hostless PCM did not reach RUNNING")

    def close(self):
        for handle in reversed(self.handles):
            self.lib.snd_pcm_close(handle)
        self.handles.clear()


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


def smoke(duration, log_path=None, interactive=False):
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
    event_path = find_input_event()
    output = open(log_path, "a") if log_path else None
    hostless = None
    armed = False
    rx_armed = False
    control_prestates = []
    events = 0

    try:
        log_line(output, "kernel=%s card=%d playback=%d capture=%d event=%s"
                 % (release, card, playback["device"], capture["device"],
                    event_path))
        if interactive:
            print("\nTest de proximite ultrasonique Elliptic", flush=True)
            print("Pose le telephone face vers toi, sans rien devant le haut "
                  "de l'ecran.", flush=True)
            input("Quand le capteur est bien DECOUVERT, appuie sur Entree... ")

        # OxygenOS enables the Elliptic engine before opening its hostless
        # TX/RX PCMs. Some firmware revisions do not begin processing when
        # that order is reversed.
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
                    if not wait_for_state(event_file, "near", 15, output):
                        raise SmokeError("no near event after cover gesture "
                                         "in cycle %d" % cycle)
                    events += 1
                    print("Near recu.", flush=True)

                    input("DECOUVRE completement le haut de l'ecran, puis "
                          "appuie sur Entree... ")
                    if not wait_for_state(event_file, "far", 15, output):
                        raise SmokeError("no far event after uncover gesture "
                                         "in cycle %d" % cycle)
                    events += 1
                    print("Far recu.", flush=True)
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
        STATE_FILE.write_text("unknown\n")
        if output:
            output.close()

    if not events:
        raise SmokeError("no proximity event received during the bounded run")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=60.0)
    parser.add_argument("--log", type=pathlib.Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--interactive", action="store_true", dest="interactive")
    mode.add_argument("--monitor", action="store_false", dest="interactive")
    parser.set_defaults(interactive=True)
    args = parser.parse_args(argv)
    if args.duration <= 0 or args.duration > 300:
        parser.error("duration must be in ]0, 300] seconds")
    if args.interactive and args.log is None:
        args.log = pathlib.Path("/home/user/proximity-test-%s.log"
                                % time.strftime("%Y%m%d-%H%M%S"))
    if args.interactive and os.geteuid() != 0:
        command = ["doas", sys.executable, str(pathlib.Path(__file__).resolve())]
        command.extend(sys.argv[1:])
        os.execvp(command[0], command)
    try:
        result = smoke(args.duration, args.log, args.interactive)
        if args.interactive:
            print("\nPASS: trois cycles near/far recus.")
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
