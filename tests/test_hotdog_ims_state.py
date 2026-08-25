from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


HARNESS = r'''#include "hotdog-ims-state.h"
#include <stdio.h>
#include <string.h>
int main(int argc,char **argv) { struct hotdog_ims_runtime_state s={.generation=4},r;
 strcpy(s.boot_id,"01234567-89ab-cdef-0123-456789abcdef");
 s.subscriptions[0].populated=true;
 s.subscriptions[0].ims.registration=HOTDOG_IMS_REGISTERED;
 s.subscriptions[0].ims.rat=HOTDOG_IMS_RAT_LTE;
 s.subscriptions[0].ims.capabilities=HOTDOG_IMS_CAP_VOICE|HOTDOG_IMS_CAP_SMS;
 s.subscriptions[0].ims.limited_capabilities=HOTDOG_IMS_CAP_VIDEO;
 s.subscriptions[0].ims.voice_rat=HOTDOG_IMS_RAT_LTE;
 s.subscriptions[0].ims.video_rat=HOTDOG_IMS_RAT_WLAN;
 s.subscriptions[0].ims.sms_rat=HOTDOG_IMS_RAT_LTE;
 if(!strcmp(argv[2],"leak")) s.subscriptions[1].ims.registration=HOTDOG_IMS_REGISTERING;
 if(!strcmp(argv[2],"overlap")) s.subscriptions[0].ims.limited_capabilities|=HOTDOG_IMS_CAP_VOICE;
 int result=hotdog_ims_runtime_write(argv[1],&s); printf("write=%d\n",result);
 if(!result && argc>3) { result=hotdog_ims_runtime_read(argv[1],&r);
  printf("read=%d gen=%u reg=%u rat=%u caps=%u limited=%u service-rats=%u/%u/%u\n",
   result,r.generation,r.subscriptions[0].ims.registration,r.subscriptions[0].ims.rat,
   r.subscriptions[0].ims.capabilities,r.subscriptions[0].ims.limited_capabilities,
   r.subscriptions[0].ims.voice_rat,r.subscriptions[0].ims.video_rat,
   r.subscriptions[0].ims.sms_rat); }
 return 0; }
'''


class HotdogImsStateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(
            ["pkg-config", "--cflags", "--libs", "glib-2.0"], check=True,
            capture_output=True, text=True,
        ).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "ims-state.c"
        cls.binary = Path(cls._temporary.name) / "ims-state"
        source.write_text(HARNESS)
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), str(SOURCE / "hotdog-ims-state.c"),
             str(SOURCE / "hotdog-telephony.c"), str(source), *flags,
             "-o", str(cls.binary)], check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_round_trip_preserves_only_bounded_ims_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ims-state"
            output = subprocess.run(
                [str(self.binary), str(path), "valid", "read"], check=True,
                capture_output=True, text=True,
            ).stdout
            self.assertIn("write=0", output)
            self.assertIn(
                "read=0 gen=4 reg=2 rat=1 caps=5 limited=2 service-rats=1/2/1",
                output,
            )
            content = path.read_text()
            for private in ("iccid", "imsi", "number", "operator"):
                self.assertNotIn(private, content.lower())

    def test_absent_subscription_and_overlapping_capabilities_are_rejected(self) -> None:
        for case in ("leak", "overlap"):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "ims-state"
                output = subprocess.run(
                    [str(self.binary), str(path), case], check=True,
                    capture_output=True, text=True,
                ).stdout
                self.assertNotIn("write=0", output)
                self.assertFalse(path.exists())

    def test_reader_rejects_unknown_key_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ims-state"
            subprocess.run([str(self.binary), str(path), "valid"], check=True)
            path.write_text(path.read_text() + "unknown=x\n")
            reader_source = Path(directory) / "reader.c"
            reader = Path(directory) / "reader"
            reader_source.write_text(
                '#include "hotdog-ims-state.h"\n#include <stdio.h>\n'
                'int main(int c,char**v){struct hotdog_ims_runtime_state s;(void)c;'
                'printf("%d\\n",hotdog_ims_runtime_read(v[1],&s));}\n'
            )
            flags = subprocess.run(
                ["pkg-config", "--cflags", "--libs", "glib-2.0"], check=True,
                capture_output=True, text=True,
            ).stdout.split()
            subprocess.run(
                ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                 "-I", str(SOURCE), str(SOURCE / "hotdog-ims-state.c"),
                 str(SOURCE / "hotdog-telephony.c"), str(reader_source),
                 *flags, "-o", str(reader)], check=True,
            )
            result = subprocess.run([str(reader), str(path)], check=True,
                                    capture_output=True, text=True).stdout.strip()
            self.assertEqual(result, "-61")

            subprocess.run([str(self.binary), str(path), "valid"], check=True)
            path.write_text(path.read_text() + "capabilities=1\n")
            result = subprocess.run([str(reader), str(path)], check=True,
                                    capture_output=True, text=True).stdout.strip()
            self.assertNotEqual(result, "0")

            target = Path(directory) / "target"
            link = Path(directory) / "link"
            target.write_text(path.read_text())
            link.symlink_to(target)
            result = subprocess.run([str(reader), str(link)], check=True,
                                    capture_output=True, text=True).stdout.strip()
            self.assertEqual(result, "-40")


if __name__ == "__main__":
    unittest.main()
