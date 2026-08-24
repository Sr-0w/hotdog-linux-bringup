from __future__ import annotations

import struct
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"


def tlv(kind: int, value: bytes) -> bytes:
    return bytes([kind]) + struct.pack("<H", len(value)) + value


def fixture(path: Path) -> None:
    metadata = (
        struct.pack("<II", 10, 0xA1) + b"MCFG_TRL"
        + tlv(0x01, struct.pack("<I", 0x08019809))
        + tlv(0x03, b"PUBLIC_TEST_OPERATOR")
        + tlv(0x04, bytes([0, 1]) + struct.pack("<I", 123456))
        + tlv(0x05, struct.pack("<I", 0x08019809))
        + tlv(0x06, bytes([0, 1]) + struct.pack("<HH", 123, 45))
        + tlv(0x07, struct.pack("<I", 0x14))
        + tlv(0x09, b"99999999,8888888")
    )
    metadata_length = len(metadata) + 4
    trailer_offset = metadata_length + 4
    path.write_bytes(
        b"PUBLIC_MBN_PAYLOAD"
        + struct.pack("<I", metadata_length)
        + metadata
        + struct.pack("<I", trailer_offset)
    )


class HotdogMbnTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "hotdog-mbn-inspect"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-mbn.c"),
                str(SOURCE / "hotdog-mbn-inspect.c"), "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def run_fixture(self, iccid: str, mcc: int = 0, mnc: int = 0) -> str:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mcfg_sw.mbn"
            fixture(path)
            result = subprocess.run(
                [str(self.binary), str(path), iccid, str(mcc), str(mnc)],
                check=True, capture_output=True, text=True,
            )
            return result.stdout

    def test_parses_public_metadata(self) -> None:
        output = self.run_fixture("1234560000000000000")
        self.assertIn("carrier=PUBLIC_TEST_OPERATOR", output)
        self.assertIn("iin[0]=123456", output)
        self.assertIn("plmn[0]=123-45", output)
        self.assertIn("capability=0x00000014", output)

    def test_match_precedence(self) -> None:
        self.assertIn("match=long-iin", self.run_fixture("9999999900000000000", 123, 45))
        self.assertIn("match=iin", self.run_fixture("1234560000000000000", 123, 45))
        self.assertIn("match=plmn", self.run_fixture("7777770000000000000", 123, 45))
        self.assertIn("match=none", self.run_fixture("7777770000000000000", 321, 54))

    def test_rejects_truncated_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.mbn"
            path.write_bytes(b"too-short")
            result = subprocess.run([str(self.binary), str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
