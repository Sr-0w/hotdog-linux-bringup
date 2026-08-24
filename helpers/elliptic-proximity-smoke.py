#!/usr/bin/env python3
"""Bounded smoke test for the OnePlus Elliptic ultrasonic proximity path."""

import argparse
import os
import pathlib
import re
import select
import signal
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
INPUT_NAME = "Elliptic ultrasonic proximity"
STATE_FILE = pathlib.Path("/run/hotdog-proximity")


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
        devices.append({
            "card": int(card),
            "device": int(device),
            "name": name.strip(),
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
    subprocess.run(command, check=True, stdout=subprocess.PIPE,
                   stderr=subprocess.PIPE, text=True)


def start_hostless(card, playback, capture):
    playback_cmd = [
        "aplay", "-q", "-D", "hw:%d,%d" % (card, playback),
        "-t", "raw", "-f", "S16_LE", "-r", "48000", "-c", "1",
        "/dev/zero",
    ]
    capture_cmd = [
        "arecord", "-q", "-D", "hw:%d,%d" % (card, capture),
        "-t", "raw", "-f", "S16_LE", "-r", "48000", "-c", "1",
        "/dev/null",
    ]
    processes = []
    try:
        processes.append(subprocess.Popen(playback_cmd,
                                          start_new_session=True))
        processes.append(subprocess.Popen(capture_cmd,
                                          start_new_session=True))
        time.sleep(0.5)
        for process in processes:
            if process.poll() is not None:
                raise SmokeError("hostless PCM exited early with status %d"
                                 % process.returncode)
        return processes
    except Exception:
        stop_processes(processes)
        raise


def stop_processes(processes):
    for process in processes:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
    deadline = time.monotonic() + 2
    for process in processes:
        remaining = max(0, deadline - time.monotonic())
        try:
            process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def log_line(output, line):
    print(line, flush=True)
    if output:
        output.write(line + "\n")
        output.flush()


def smoke(duration, log_path=None):
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
    event_path = find_input_event()
    output = open(log_path, "a") if log_path else None
    processes = []
    armed = False
    mixer_enabled = False
    events = 0

    try:
        log_line(output, "kernel=%s card=%d playback=%d capture=%d event=%s"
                 % (release, card, playback["device"], capture["device"],
                    event_path))
        run_checked(["amixer", "-q", "-c", str(card), "cset",
                     "name=%s" % MIXER_CONTROL, "1"])
        mixer_enabled = True
        processes = start_hostless(card, playback["device"],
                                   capture["device"])
        enable.write_text("1\n")
        armed = True

        deadline = time.monotonic() + duration
        with event_path.open("rb", buffering=0) as event_file:
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
                events += 1
    finally:
        if armed:
            try:
                enable.write_text("0\n")
            except OSError as error:
                log_line(output, "ERROR disable: %s" % error)
        stop_processes(processes)
        if mixer_enabled:
            try:
                run_checked(["amixer", "-q", "-c", str(card), "cset",
                             "name=%s" % MIXER_CONTROL, "0"])
            except (OSError, subprocess.CalledProcessError) as error:
                log_line(output, "ERROR mixer rollback: %s" % error)
        STATE_FILE.write_text("unknown\n")
        if output:
            output.close()

    if not events:
        raise SmokeError("no proximity event received during the bounded run")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=60.0)
    parser.add_argument("--log", type=pathlib.Path)
    args = parser.parse_args()
    if args.duration <= 0 or args.duration > 300:
        parser.error("duration must be in ]0, 300] seconds")
    try:
        return smoke(args.duration, args.log)
    except (OSError, SmokeError, subprocess.CalledProcessError) as error:
        print("ERROR: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
