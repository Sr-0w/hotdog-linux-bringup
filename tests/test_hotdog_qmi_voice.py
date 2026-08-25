from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers" / "hotdog-radio"


HARNESS = r'''#include "hotdog-qmi-voice.h"
#include <stdio.h>
#include <string.h>
int main(void) {
    struct hotdog_call call={.transport=HOTDOG_TRANSPORT_CS,.direction=HOTDOG_CALL_MO,
        .state=HOTDOG_CALL_DIALING}; const gchar *number; guint8 id,digit;
    QmiMessageVoiceDialCallInput *dial=NULL; QmiMessageVoiceStartContinuousDtmfInput *dtmf=NULL;
    strcpy(call.number,"+32000000000");
    if(hotdog_qmi_voice_dial_input(&call,&dial)) return 1;
    qmi_message_voice_dial_call_input_get_calling_number(dial,&number,NULL);
    if(hotdog_qmi_voice_start_dtmf_input(7,'5',&dtmf)) return 2;
    qmi_message_voice_start_continuous_dtmf_input_get_data(dtmf,&id,&digit,NULL);
    printf("number=%s call=%u digit=%c\n",number,id,digit);
    qmi_message_voice_dial_call_input_unref(dial);
    qmi_message_voice_start_continuous_dtmf_input_unref(dtmf); return 0;
}
'''


class HotdogQmiVoiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        flags = subprocess.run(["pkg-config", "--cflags", "--libs", "qmi-glib", "glib-2.0"],
                               check=True, capture_output=True, text=True).stdout.split()
        cls._temporary = tempfile.TemporaryDirectory()
        source = Path(cls._temporary.name) / "voice.c"
        cls.binary = Path(cls._temporary.name) / "voice"
        source.write_text(HARNESS)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                        "-I", str(SOURCE), str(SOURCE / "hotdog-qmi-voice.c"),
                        str(source), *flags, "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_cs_dial_and_dtmf_preserve_fields(self) -> None:
        output = subprocess.run([str(self.binary)], check=True,
                                capture_output=True, text=True).stdout.strip()
        self.assertEqual(output, "number=+32000000000 call=7 digit=5")

    def test_ims_or_video_cannot_fall_through_qmi_voice(self) -> None:
        source = (SOURCE / "hotdog-qmi-voice.c").read_text()
        self.assertIn("call->transport != HOTDOG_TRANSPORT_CS", source)
        self.assertIn("call->video", source)


if __name__ == "__main__":
    unittest.main()
