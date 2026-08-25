from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "aports/temp/modemmanager/0005-qmi-preserve-sms-ims-transport-domain.patch"


def extract_added_file(patch: str, path: str) -> str:
    marker = f"+++ b/{path}"
    lines = patch.splitlines()
    try:
        index = lines.index(marker) + 1
    except ValueError as error:
        raise AssertionError(f"missing added file {path}") from error
    while index < len(lines) and not lines[index].startswith("@@"):
        index += 1
    index += 1
    output: list[str] = []
    while index < len(lines) and not lines[index].startswith("diff --git "):
        line = lines[index]
        if line.startswith("+"):
            output.append(line[1:])
        elif line.startswith(" "):
            output.append(line[1:])
        index += 1
    return "\n".join(output) + "\n"


def subscription(
    populated: bool,
    registration: str = "none",
    rat: str = "unknown",
    capabilities: int = 0,
    limited: int = 0,
    sip_code: int = 0,
    voice_rat: str = "unknown",
    video_rat: str = "unknown",
    sms_rat: str = "unknown",
) -> str:
    return "\n".join(
        (
            f"populated={'true' if populated else 'false'}",
            f"registration={registration}",
            f"rat={rat}",
            f"capabilities={capabilities}",
            f"limited-capabilities={limited}",
            f"sip-code={sip_code}",
            f"voice-rat={voice_rat}",
            f"video-rat={video_rat}",
            f"sms-rat={sms_rat}",
        )
    )


def runtime_state(boot_id: str, generation: int = 7) -> str:
    return f"""[hotdog-ims]
schema=1
boot-id={boot_id}
generation={generation}

[subscription0]
{subscription(True, 'registered', 'lte', 4, sms_rat='lte')}

[subscription1]
{subscription(True, 'registered', 'wlan', 0, 4, sms_rat='wlan')}

[subscription2]
{subscription(False)}
"""


class ModemManagerSmsImsPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temp.name)
        patch = PATCH.read_text(encoding="ascii")
        (cls.directory / "mm-hotdog-ims.c").write_text(
            extract_added_file(patch, "src/mm-hotdog-ims.c"), encoding="ascii"
        )
        (cls.directory / "mm-hotdog-ims.h").write_text(
            extract_added_file(patch, "src/mm-hotdog-ims.h"), encoding="ascii"
        )
        (cls.directory / "mm-base-modem.h").write_text(
            "#include <glib-object.h>\n"
            "typedef GObject MMBaseModem;\n"
            "#define MM_IS_BASE_MODEM(value) TRUE\n",
            encoding="ascii",
        )
        (cls.directory / "mm-iface-modem.h").write_text(
            "#include <glib-object.h>\n"
            "typedef GObject MmGdbusModem;\n"
            '#define MM_IFACE_MODEM_DBUS_SKELETON "iface-modem-dbus-skeleton"\n'
            "guint mm_gdbus_modem_get_primary_sim_slot(MmGdbusModem *self);\n",
            encoding="ascii",
        )
        (cls.directory / "mm-log-object.h").write_text(
            "#define mm_obj_dbg(...) ((void)0)\n", encoding="ascii"
        )
        (cls.directory / "harness.c").write_text(
            '#include "mm-hotdog-ims.h"\n'
            "#include <stdio.h>\n"
            "#include <stdlib.h>\n"
            "int main(int argc, char **argv) {\n"
            "    gboolean available = FALSE; GError *error = NULL;\n"
            "    if (argc != 4) return 3;\n"
            "    if (!mm_hotdog_ims_sms_available_from_paths(argv[1], argv[2],\n"
            "            (guint)strtoul(argv[3], NULL, 10), &available, &error)) {\n"
            '        fprintf(stderr, "%s\\n", error ? error->message : "error");\n'
            "        g_clear_error(&error); return 2;\n"
            "    }\n"
            '    printf("%u\\n", available); return 0;\n'
            "}\n",
            encoding="ascii",
        )
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "glib-2.0", "gobject-2.0"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.split()
        cls.binary = cls.directory / "ims-state-test"
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
                str(cls.directory),
                str(cls.directory / "mm-hotdog-ims.c"),
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

    def run_state(self, text: str, slot: int, *, symlink: bool = False) -> subprocess.CompletedProcess[str]:
        case = Path(tempfile.mkdtemp(dir=self.directory))
        boot_id = "11111111-2222-3333-4444-555555555555"
        boot = case / "boot-id"
        boot.write_text(boot_id + "\n", encoding="ascii")
        real_state = case / "state.real"
        real_state.write_text(text, encoding="ascii")
        state = case / "state"
        if symlink:
            state.symlink_to(real_state)
        else:
            real_state.rename(state)
        return subprocess.run(
            [str(self.binary), str(state), str(boot), str(slot)],
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_patch_preserves_all_three_wms_domain_fields(self) -> None:
        patch = PATCH.read_text(encoding="ascii")
        self.assertIn("qmi_message_wms_raw_send_input_set_sms_on_ims", patch)
        self.assertIn("qmi_message_wms_send_from_memory_storage_input_set_sms_on_ims", patch)
        self.assertIn("qmi_message_wms_send_ack_input_set_sms_on_ims", patch)
        self.assertIn("qmi_indication_wms_event_report_output_get_sms_on_ims", patch)

    def test_primary_slot_selects_available_not_limited_sms(self) -> None:
        boot_id = "11111111-2222-3333-4444-555555555555"
        slot1 = self.run_state(runtime_state(boot_id), 1)
        slot2 = self.run_state(runtime_state(boot_id), 2)
        slot3 = self.run_state(runtime_state(boot_id), 3)
        self.assertEqual((slot1.returncode, slot1.stdout.strip()), (0, "1"))
        self.assertEqual((slot2.returncode, slot2.stdout.strip()), (0, "0"))
        self.assertEqual((slot3.returncode, slot3.stdout.strip()), (0, "0"))

    def test_stale_boot_and_unbounded_generation_fail_closed(self) -> None:
        stale = self.run_state(runtime_state("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), 1)
        unbounded = self.run_state(
            runtime_state("11111111-2222-3333-4444-555555555555", 2**32), 1
        )
        self.assertEqual(stale.returncode, 2)
        self.assertIn("stale IMS state boot identity", stale.stderr)
        self.assertEqual(unbounded.returncode, 2)
        self.assertIn("invalid IMS state identity", unbounded.stderr)

    def test_symlink_and_writable_state_fail_closed(self) -> None:
        boot_id = "11111111-2222-3333-4444-555555555555"
        symlink = self.run_state(runtime_state(boot_id), 1, symlink=True)
        self.assertEqual(symlink.returncode, 2)

        case = Path(tempfile.mkdtemp(dir=self.directory))
        boot = case / "boot-id"
        state = case / "state"
        boot.write_text(boot_id + "\n", encoding="ascii")
        state.write_text(runtime_state(boot_id), encoding="ascii")
        os.chmod(state, 0o664)
        writable = subprocess.run(
            [str(self.binary), str(state), str(boot), "1"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(writable.returncode, 2)
        self.assertIn("invalid IMS state file", writable.stderr)


if __name__ == "__main__":
    unittest.main()
