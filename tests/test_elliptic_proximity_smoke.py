import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "helpers" / "elliptic-proximity-smoke.py"
SPEC = importlib.util.spec_from_file_location("elliptic_proximity_smoke", SCRIPT)
smoke = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(smoke)


class EllipticProximitySmokeTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
