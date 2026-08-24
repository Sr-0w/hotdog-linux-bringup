import importlib.util
import os
import pathlib
import tempfile
import unittest
import unittest.mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "helpers" / "elliptic-proximity-smoke.py"
SPEC = importlib.util.spec_from_file_location("elliptic_proximity_smoke", SCRIPT)
smoke = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(smoke)


class EllipticProximitySmokeTests(unittest.TestCase):
    def test_parse_pcm_devices_strips_alsa_marker(self):
        devices = smoke.parse_pcm_devices(
            "00-03: Quaternary MI2S_RX Hostless Playback (*) :  : playback 1\n"
        )

        self.assertEqual(
            devices[0]["name"], "Quaternary MI2S_RX Hostless Playback"
        )

    def test_parses_and_selects_exact_hostless_pcms(self):
        devices = smoke.parse_pcm_devices("""
00-00: MultiMedia1 (*) : playback 1 : capture 1
00-02: Quaternary MI2S_RX Hostless Playback : playback 1
00-03: SLIMBUS2_HOSTLESS Capture : capture 1
""")

        playback = smoke.find_pcm(
            devices, smoke.PCM_PLAYBACK_NAME, "playback")
        capture = smoke.find_pcm(devices, smoke.PCM_CAPTURE_NAME, "capture")

        self.assertEqual((playback["card"], playback["device"]), (0, 2))
        self.assertEqual((capture["card"], capture["device"]), (0, 3))

    def test_rejects_ambiguous_pcm_name(self):
        devices = smoke.parse_pcm_devices("""
00-02: SLIMBUS2_HOSTLESS Capture : capture 1
00-03: SLIMBUS2_HOSTLESS Capture : capture 1
""")

        with self.assertRaises(smoke.SmokeError):
            smoke.find_pcm(devices, smoke.PCM_CAPTURE_NAME, "capture")

    def test_input_event_layout_matches_aarch64(self):
        self.assertEqual(smoke.INPUT_EVENT.size, 24)

    def test_reads_single_mixer_control_value(self):
        output = """numid=1,iface=MIXER,name='Example'
  ; type=ENUMERATED,access=rw------,values=1,items=2
  : values=1
"""
        with unittest.mock.patch.object(
                smoke, "run_checked", return_value=output):
            self.assertEqual(smoke.read_control(0, "Example"), "1")

    def test_reads_stock_compatible_near_event(self):
        read_fd, write_fd = os.pipe()
        with tempfile.TemporaryDirectory() as directory:
            state_file = pathlib.Path(directory) / "state"
            os.write(write_fd, smoke.INPUT_EVENT.pack(
                0, 0, smoke.EV_MSC, smoke.MSC_RAW, 1))
            os.close(write_fd)
            with os.fdopen(read_fd, "rb", buffering=0) as event_file:
                with unittest.mock.patch.object(smoke, "STATE_FILE", state_file):
                    state = smoke.read_proximity_event(
                        event_file, 0.1, output=None)

            self.assertEqual(state, "near")
            self.assertEqual(state_file.read_text(), "near\n")


if __name__ == "__main__":
    unittest.main()
