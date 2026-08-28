import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "build-hotdog-regional-vbmeta.py"


def stock_vbmeta(marker: bytes = b"") -> bytes:
    data = bytearray(8192)
    data[:4] = b"AVB0"
    data[256 : 256 + len(marker)] = marker
    return bytes(data)


class RegionalVbmetaTests(unittest.TestCase):
    def run_builder(self, in_data: bytes, eu_data: bytes):
        temporary = tempfile.TemporaryDirectory()
        root = pathlib.Path(temporary.name)
        in_path = root / "IN-vbmeta.img"
        eu_path = root / "EU-vbmeta.img"
        output = root / "output"
        in_path.write_bytes(in_data)
        eu_path.write_bytes(eu_data)
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--in-vbmeta",
                str(in_path),
                "--eu-vbmeta",
                str(eu_path),
                "--outdir",
                str(output),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return temporary, output, result

    def test_identical_regions_produce_one_common_image(self):
        temporary, output, result = self.run_builder(stock_vbmeta(), stock_vbmeta())
        self.addCleanup(temporary.cleanup)
        self.assertEqual(result.returncode, 0, result.stderr)
        image = (output / "common" / "vbmeta-disabled.img").read_bytes()
        self.assertEqual(len(image), 65536)
        self.assertEqual(int.from_bytes(image[120:124], "big"), 3)
        self.assertEqual(image[:120], stock_vbmeta()[:120])
        self.assertEqual(image[124:8192], stock_vbmeta()[124:])
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertFalse(manifest["regional_split_required"])

    def test_different_regions_produce_two_images(self):
        temporary, output, result = self.run_builder(
            stock_vbmeta(b"IN"), stock_vbmeta(b"EU")
        )
        self.addCleanup(temporary.cleanup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((output / "HD1911-IN" / "vbmeta-disabled.img").is_file())
        self.assertTrue((output / "HD1913-EU" / "vbmeta-disabled.img").is_file())
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertTrue(manifest["regional_split_required"])

    def test_rejects_non_stock_flags(self):
        bad = bytearray(stock_vbmeta())
        bad[120:124] = (2).to_bytes(4, "big")
        temporary, _output, result = self.run_builder(bytes(bad), stock_vbmeta())
        self.addCleanup(temporary.cleanup)
        self.assertEqual(result.returncode, 2)
        self.assertIn("expected stock flags 0", result.stderr)


if __name__ == "__main__":
    unittest.main()
