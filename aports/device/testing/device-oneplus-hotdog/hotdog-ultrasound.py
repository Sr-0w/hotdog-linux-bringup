#!/usr/bin/env python3
"""Primitives du chemin audio ultrason Elliptic.

Le demon d'armement et le test guide ont besoin des memes gestes : trouver les
PCM sans hote, lire et poser les controles mixer, ouvrir et fermer la paire de
flux. Ils vivaient dans le script de test, que le demon importait -- un service
qui depend d'un instrument de diagnostic, donc un instrument qu'on ne peut plus
sortir de l'image sans casser le service.

Ils vivent ici maintenant. Le demon et le test importent tous les deux ce
module, et le test peut partir dans le paquet de bring-up.
"""
import ctypes
import pathlib
import re
import subprocess

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

# 699 est la proximite globale ; 693 le mode combine seul.
PROXIMITY_MODE = 699

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
