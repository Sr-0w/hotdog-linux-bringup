import importlib.util
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = (
    ROOT
    / "aports/device/testing/device-oneplus-hotdog"
    / "hotdog-elliptic-calibration.py"
)
SPEC = importlib.util.spec_from_file_location("hotdog_elliptic_calibration", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EllipticCalibrationTests(unittest.TestCase):
    def test_accepts_a_nonzero_448_byte_calibration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "calibration.bin"
            expected = bytes((index % 251) + 1 for index in range(448))
            path.write_bytes(expected)
            self.assertEqual(MODULE.read_calibration(path), expected)

    def test_rejects_wrong_size(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "calibration.bin"
            path.write_bytes(b"x" * 447)
            with self.assertRaisesRegex(MODULE.CalibrationError, "expected 448"):
                MODULE.read_calibration(path)

    def test_rejects_all_zero_calibration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "calibration.bin"
            path.write_bytes(bytes(448))
            with self.assertRaisesRegex(MODULE.CalibrationError, "all-zero"):
                MODULE.read_calibration(path)

    def test_atomic_write_replaces_the_complete_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "firmware" / "calibration.bin"
            expected = b"a" * 448
            MODULE.write_atomic(path, expected)
            self.assertEqual(path.read_bytes(), expected)
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)


if __name__ == "__main__":
    unittest.main()
