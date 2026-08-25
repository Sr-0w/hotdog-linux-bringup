from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest

from tests.test_modemmanager_sms_ims_patch import extract_added_file, subscription


ROOT = Path(__file__).resolve().parents[1]
LIBQMI_PATCH = ROOT / "aports/temp/libqmi/0002-voice-expose-ip-call-dial-attributes.patch"
SMS_PATCH = ROOT / "aports/temp/modemmanager/0005-qmi-preserve-sms-ims-transport-domain.patch"
VOICE_PATCH = ROOT / "aports/temp/modemmanager/0006-qmi-select-ip-voice-calls-from-ims-state.patch"


def voice_state(boot_id: str, *, limited: bool = False) -> str:
    capabilities = 0 if limited else 1
    limited_capabilities = 1 if limited else 0
    return f"""[hotdog-ims]
schema=1
boot-id={boot_id}
generation=9

[subscription0]
{subscription(True, 'registered', 'lte', capabilities, limited_capabilities, voice_rat='lte')}

[subscription1]
{subscription(False)}

[subscription2]
{subscription(False)}
"""


class ModemManagerVoiceImsPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temp.name)
        source_dir = cls.directory / "src"
        source_dir.mkdir()
        sms_patch = SMS_PATCH.read_text(encoding="ascii")
        (source_dir / "mm-hotdog-ims.c").write_text(
            extract_added_file(sms_patch, "src/mm-hotdog-ims.c"), encoding="ascii"
        )
        (source_dir / "mm-hotdog-ims.h").write_text(
            extract_added_file(sms_patch, "src/mm-hotdog-ims.h"), encoding="ascii"
        )
        subprocess.run(["git", "init", "-q"], cwd=cls.directory, check=True)
        subprocess.run(["git", "add", "src"], cwd=cls.directory, check=True)
        subprocess.run(
            [
                "git",
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-qm",
                "base",
            ],
            cwd=cls.directory,
            check=True,
        )
        subprocess.run(
            [
                "git",
                "apply",
                "--include=src/mm-hotdog-ims.c",
                "--include=src/mm-hotdog-ims.h",
                str(VOICE_PATCH),
            ],
            cwd=cls.directory,
            check=True,
        )
        (source_dir / "mm-base-modem.h").write_text(
            "#include <glib-object.h>\n"
            "typedef GObject MMBaseModem;\n"
            "#define MM_IS_BASE_MODEM(value) TRUE\n",
            encoding="ascii",
        )
        (source_dir / "mm-iface-modem.h").write_text(
            "#include <glib-object.h>\n"
            "typedef GObject MmGdbusModem;\n"
            '#define MM_IFACE_MODEM_DBUS_SKELETON "iface-modem-dbus-skeleton"\n'
            "guint mm_gdbus_modem_get_primary_sim_slot(MmGdbusModem *self);\n",
            encoding="ascii",
        )
        (source_dir / "mm-log-object.h").write_text(
            "#include <stdarg.h>\n"
            "static inline void mm_obj_dbg_stub(void *obj, const char *format, ...) "
            "{ (void)obj; (void)format; }\n"
            "#define mm_obj_dbg mm_obj_dbg_stub\n",
            encoding="ascii",
        )
        (cls.directory / "harness.c").write_text(
            '#include "mm-hotdog-ims.h"\n'
            "#include <stdio.h>\n"
            "#include <stdlib.h>\n"
            "int main(int argc, char **argv) {\n"
            "    gboolean voice = FALSE, sms = FALSE; GError *error = NULL;\n"
            "    if (argc != 4) return 3;\n"
            "    if (!mm_hotdog_ims_voice_available_from_paths(argv[1], argv[2],\n"
            "            (guint)strtoul(argv[3], NULL, 10), &voice, &error)) return 2;\n"
            "    if (!mm_hotdog_ims_sms_available_from_paths(argv[1], argv[2],\n"
            "            (guint)strtoul(argv[3], NULL, 10), &sms, &error)) return 2;\n"
            '    printf("voice=%u sms=%u\\n", voice, sms); return 0;\n'
            "}\n",
            encoding="ascii",
        )
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "glib-2.0", "gobject-2.0"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.split()
        cls.binary = cls.directory / "voice-state-test"
        subprocess.run(
            [
                "cc",
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-ffunction-sections",
                "-fdata-sections",
                "-I",
                str(source_dir),
                str(source_dir / "mm-hotdog-ims.c"),
                str(cls.directory / "harness.c"),
                "-Wl,--gc-sections",
                *flags,
                "-o",
                str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def run_state(self, state_text: str) -> subprocess.CompletedProcess[str]:
        case = Path(tempfile.mkdtemp(dir=self.directory))
        boot_id = "11111111-2222-3333-4444-555555555555"
        state = case / "state"
        boot = case / "boot-id"
        state.write_text(state_text, encoding="ascii")
        boot.write_text(boot_id + "\n", encoding="ascii")
        return subprocess.run(
            [str(self.binary), str(state), str(boot), "1"],
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_libqmi_exposes_exact_oos_dial_tlvs(self) -> None:
        patch = LIBQMI_PATCH.read_text(encoding="ascii")
        for name, identifier, value_format in (
            ("Call Type", "0x10", "guint8"),
            ("Audio Attributes", "0x18", "guint64"),
            ("Video Attributes", "0x19", "guint64"),
        ):
            self.assertIn(f'+                     {{ "name"          : "{name}"', patch)
            self.assertIn(f'+                       "id"            : "{identifier}"', patch)
            self.assertIn(f'+                       "format"        : "{value_format}"', patch)

    def test_dial_uses_oos_ip_voice_attributes_only_with_voice_capability(self) -> None:
        patch = VOICE_PATCH.read_text(encoding="ascii")
        self.assertIn("mm_hotdog_ims_voice_available", patch)
        self.assertIn("QMI_VOICE_CALL_TYPE_VOICE_IP", patch)
        self.assertIn("set_audio_attributes (input, 0x3", patch)
        self.assertIn("set_video_attributes (input, 0x0", patch)

    def test_available_voice_is_distinct_from_sms(self) -> None:
        boot_id = "11111111-2222-3333-4444-555555555555"
        result = self.run_state(voice_state(boot_id))
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "voice=1 sms=0"))

    def test_limited_voice_does_not_select_ip_dial(self) -> None:
        boot_id = "11111111-2222-3333-4444-555555555555"
        result = self.run_state(voice_state(boot_id, limited=True))
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "voice=0 sms=0"))


if __name__ == "__main__":
    unittest.main()
