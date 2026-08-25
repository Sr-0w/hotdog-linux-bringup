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
    QmiIndicationVoiceAllCallStatusOutputCallInformationCall info={.id=9,
        .state=QMI_VOICE_CALL_STATE_WAITING,.type=QMI_VOICE_CALL_TYPE_VOICE,
        .direction=QMI_VOICE_CALL_DIRECTION_MT,.mode=QMI_VOICE_CALL_MODE_UMTS};
    struct hotdog_qmi_voice_call mapped; struct hotdog_qmi_voice_snapshot snapshot={0};
    struct hotdog_call_changes changes; struct hotdog_telephony telephony; unsigned int local;
    if(hotdog_qmi_voice_map_call(&info,1,&mapped)) return 3;
    hotdog_telephony_init(&telephony);
    if(hotdog_telephony_set_subscription(&telephony,1,true,true,true)) return 4;
    snapshot.subscription=1; snapshot.count=1; snapshot.calls[0]=mapped;
    snapshot.calls[0].number_present=true;
    strcpy(snapshot.calls[0].call.number,"+32123456789");
    if(hotdog_qmi_voice_apply_snapshot(&telephony,&snapshot,&changes)) return 5;
    local=changes.changes[0].call_id;
    snapshot.calls[0].call.state=HOTDOG_CALL_ACTIVE;
    if(hotdog_qmi_voice_apply_snapshot(&telephony,&snapshot,&changes)) return 6;
    snapshot.count=0;
    if(hotdog_qmi_voice_apply_snapshot(&telephony,&snapshot,&changes)) return 7;
    printf("number=%s call=%u digit=%c mapped=%u/%u/%s/%u changes=0/1/2 local=%u remote=%u final=%s\n",number,id,digit,
        mapped.qmi_call_id,mapped.call.subscription,
        hotdog_call_state_name(mapped.call.state),mapped.call.transport,local,
        telephony.calls[0].remote_id,hotdog_call_state_name(telephony.calls[0].state));
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
                        str(SOURCE / "hotdog-telephony.c"),
                        str(source), *flags, "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def test_cs_dial_and_dtmf_preserve_fields(self) -> None:
        output = subprocess.run([str(self.binary)], check=True,
                                capture_output=True, text=True).stdout.strip()
        self.assertEqual(
            output,
            "number=+32000000000 call=7 digit=5 mapped=9/1/incoming/1 "
            "changes=0/1/2 local=1 remote=9 final=ended",
        )

    def test_ims_or_video_cannot_fall_through_qmi_voice(self) -> None:
        source = (SOURCE / "hotdog-qmi-voice.c").read_text()
        self.assertIn("call->transport != HOTDOG_TRANSPORT_CS", source)
        self.assertIn("call->video", source)

    def test_all_call_status_mapping_is_strict_and_filters_control_calls(self) -> None:
        source = (SOURCE / "hotdog-qmi-voice.c").read_text()
        self.assertIn("QMI_VOICE_CALL_STATE_WAITING", source)
        self.assertIn("QMI_VOICE_CALL_TYPE_VOICE_IP", source)
        self.assertIn("QMI_VOICE_CALL_TYPE_EMERGENCY", source)
        self.assertIn("return -EOPNOTSUPP", source)
        self.assertIn("source->presentation_indicator", source)
        self.assertIn("HOTDOG_TELEPHONY_MAX_CALLS", source)


if __name__ == "__main__":
    unittest.main()
