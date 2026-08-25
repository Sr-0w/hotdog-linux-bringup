from __future__ import annotations

from pathlib import Path
import hashlib
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "aports/temp/modemmanager/0007-qmi-request-radio-reattest-after-PIN.patch"
APKBUILD = ROOT / "aports/temp/modemmanager/APKBUILD"


class ModemManagerPinReattestPatchTests(unittest.TestCase):
    def test_patch_requests_reattest_only_after_successful_pin_results(self) -> None:
        content = PATCH.read_text(encoding="utf-8")
        self.assertEqual(content.count("request_radio_reattest (MM_SIM_QMI"), 2)
        self.assertIn("qmi_message_uim_verify_pin_output_get_result", content)
        self.assertIn("qmi_message_dms_uim_verify_pin_output_get_result", content)
        lines = content.splitlines()
        handoffs = [
            index for index, line in enumerate(lines)
            if "request_radio_reattest (MM_SIM_QMI" in line
        ]
        self.assertEqual(len(handoffs), 2)
        for index in handoffs:
            self.assertIn("g_task_return_boolean (task, TRUE)", lines[index + 1])

    def test_request_is_atomic_root_only_and_contains_no_pin(self) -> None:
        content = PATCH.read_text(encoding="utf-8")
        for marker in ("O_NOFOLLOW", "O_EXCL", "0600", "fsync (descriptor)",
                       "renameat", "fsync (directory)", '"pin-unlocked\\n"'):
            self.assertIn(marker, content)
        self.assertNotRegex(content, re.compile(r"[0-9]{4,8}.*PIN|PIN.*[0-9]{4,8}"))
        self.assertIn("cannot request guarded radio re-attestation", content)

    def test_apkbuild_tracks_patch_and_exact_sha512(self) -> None:
        apkbuild = APKBUILD.read_text(encoding="utf-8")
        digest = hashlib.sha512(PATCH.read_bytes()).hexdigest()
        self.assertIn("pkgrel=9", apkbuild)
        self.assertIn("0007-qmi-request-radio-reattest-after-PIN.patch", apkbuild)
        self.assertIn(f"{digest}  0007-qmi-request-radio-reattest-after-PIN.patch", apkbuild)


if __name__ == "__main__":
    unittest.main()
