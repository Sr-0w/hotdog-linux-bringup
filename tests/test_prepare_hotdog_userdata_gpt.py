import binascii
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest


SECTOR = 4096


def finish_header(header):
    header[16:20] = b"\0" * 4
    size = struct.unpack_from("<I", header, 12)[0]
    struct.pack_into("<I", header, 16,
                     binascii.crc32(header[:size]) & 0xFFFFFFFF)


def synthetic_image(path, sectors=128):
    entries = bytearray(128 * 128)
    entries[0:16] = bytes.fromhex("28732ac11ff811d2ba4b00a0c93ec93b")
    entries[16:32] = bytes(range(16))
    struct.pack_into("<QQQ", entries, 32, 8, 31, 0)
    boot_name = "boot".encode("utf-16le")
    entries[56:56 + len(boot_name)] = boot_name
    off = 128
    entries[off:off + 16] = bytes.fromhex("45b021b9f01dc341af444c6f280d3fae")
    entries[off + 16:off + 32] = bytes(range(16, 32))
    struct.pack_into("<QQQ", entries, off + 32, 32, sectors - 6, 0)
    root_name = "root".encode("utf-16le")
    entries[off + 56:off + 56 + len(root_name)] = root_name
    entries_crc = binascii.crc32(entries) & 0xFFFFFFFF

    header = bytearray(SECTOR)
    header[:8] = b"EFI PART"
    struct.pack_into("<IIII", header, 8, 0x00010000, 92, 0, 0)
    struct.pack_into("<QQQQ", header, 24, 1, sectors - 1, 6, sectors - 6)
    header[56:72] = bytes(range(32, 48))
    struct.pack_into("<QIII", header, 72, 2, 128, 128, entries_crc)
    finish_header(header)

    backup = bytearray(header)
    struct.pack_into("<QQ", backup, 24, sectors - 1, 1)
    struct.pack_into("<Q", backup, 72, sectors - 5)
    finish_header(backup)

    mbr = bytearray(SECTOR)
    mbr[450] = 0xEE
    struct.pack_into("<II", mbr, 454, 1, sectors - 1)
    mbr[510:512] = b"\x55\xaa"
    with path.open("wb") as output:
        output.truncate(sectors * SECTOR)
        output.seek(0)
        output.write(mbr)
        output.write(header)
        output.write(entries)
        output.seek((sectors - 5) * SECTOR)
        output.write(entries)
        output.write(backup)


class PrepareHotdogUserdataGptTests(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(__file__).resolve().parents[1]
        self.script = self.root / "scripts/prepare-hotdog-userdata-gpt.py"

    def test_grows_partition_and_builds_valid_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            source = directory / "source.img"
            output = directory / "patches"
            synthetic_image(source)
            result = subprocess.run(
                [sys.executable, str(self.script), str(source), str(output),
                 "--device-size", str(256 * SECTOR)],
                text=True, capture_output=True, check=True,
            )
            self.assertIn('"backup_lba": 255', result.stdout)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["partition"]["new_end_lba"], 250)
            self.assertEqual(manifest["target"]["backup_entries_lba"], 251)
            self.assertEqual((output / "primary-gpt.bin").stat().st_size,
                             6 * SECTOR)
            self.assertEqual((output / "backup-gpt.bin").stat().st_size,
                             5 * SECTOR)

            primary = (output / "primary-gpt.bin").read_bytes()
            header = bytearray(primary[SECTOR:2 * SECTOR])
            stored = struct.unpack_from("<I", header, 16)[0]
            header[16:20] = b"\0" * 4
            self.assertEqual(stored,
                             binascii.crc32(header[:92]) & 0xFFFFFFFF)
            self.assertEqual(struct.unpack_from("<Q", header, 32)[0], 255)

            backup = (output / "backup-gpt.bin").read_bytes()
            header = bytearray(backup[-SECTOR:])
            stored = struct.unpack_from("<I", header, 16)[0]
            header[16:20] = b"\0" * 4
            self.assertEqual(stored,
                             binascii.crc32(header[:92]) & 0xFFFFFFFF)
            self.assertEqual(struct.unpack_from("<Q", header, 24)[0], 255)
            self.assertEqual(struct.unpack_from("<Q", header, 32)[0], 1)

    def test_rejects_wrong_hash_and_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            source = directory / "source.img"
            synthetic_image(source)
            wrong = subprocess.run(
                [sys.executable, str(self.script), str(source),
                 str(directory / "patches"), "--device-size", str(256 * SECTOR),
                 "--expect-input-sha256", "0" * 64],
                text=True, capture_output=True,
            )
            self.assertEqual(wrong.returncode, 2)
            existing = directory / "existing"
            existing.mkdir()
            result = subprocess.run(
                [sys.executable, str(self.script), str(source), str(existing),
                 "--device-size", str(256 * SECTOR)],
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
