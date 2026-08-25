from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "helpers/hotdog-radio"


class HotdogTelephonyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._temporary = tempfile.TemporaryDirectory()
        cls.binary = Path(cls._temporary.name) / "hotdog-telephony-replay"
        subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                "-I", str(SOURCE), str(SOURCE / "hotdog-telephony.c"),
                str(SOURCE / "hotdog-telephony-replay.c"), "-o", str(cls.binary),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    def replay(self, content: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(self.binary)], input=content, text=True, capture_output=True)

    def test_sms_prefers_ims_and_falls_back_to_cs(self) -> None:
        ims = self.replay(
            "SUB 0 1 1 1\nIMS 0 registered lte 5 0\n"
            "SMS 0 auto 24 1 0 0 0\nSTATUS\n"
        )
        self.assertEqual(ims.returncode, 0, ims.stderr)
        self.assertIn("sms-result=0 id=1", ims.stdout)
        self.assertIn("sms1=queued,ims", ims.stdout)

        cs = self.replay("SUB 0 1 1 1\nSMS 0 auto 24 0 0 0 0\nSTATUS\n")
        self.assertIn("sms1=queued,cs", cs.stdout)

    def test_sms_transitions_delivery_and_multipart_validation(self) -> None:
        result = self.replay(
            "SUB 0 1 1 1\nSMS 0 cs 140 1 42 1 2\n"
            "SMS_STATE 1 submitted 77 0\nSMS_STATE 1 sent 77 0\n"
            "SMS_STATE 1 delivered 77 0\nSTATUS\n"
        )
        self.assertIn("sms1=delivered,cs,sub0,gen0,bytes140,ref77,error0,concat42/1/2", result.stdout)

        invalid = self.replay("SUB 0 1 1 1\nSMS 0 cs 140 0 42 3 2\n")
        self.assertIn("sms-result=-22 id=0", invalid.stdout)

        skipped = self.replay(
            "SUB 0 1 1 1\nSMS 0 cs 24 0 0 0 0\nSMS_STATE 1 sent 1 0\n"
        )
        self.assertIn("sms-state-result=-71", skipped.stdout)

    def test_delivery_reports_preserve_retry_and_terminal_status(self) -> None:
        result = self.replay(
            "SUB 0 1 1 1\nSMS 0 cs 24 1 0 0 0\n"
            "SMS_STATE 1 submitted 77 0\nSMS_STATE 1 sent 77 0\n"
            "SMS_REPORT 0 cs 77 32\nSTATUS\n"
            "SMS_REPORT 0 cs 77 0\nSMS_REPORT 0 cs 77 0\nSTATUS\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sms-report-result=0 id=1", result.stdout)
        self.assertIn("sms1=sent,cs,sub0,gen0,bytes24,ref77,error32", result.stdout)
        self.assertIn("sms1=delivered,cs,sub0,gen0,bytes24,ref77,error0", result.stdout)
        self.assertIn("sms-report-result=-114 id=1", result.stdout)

        failed = self.replay(
            "SUB 0 1 1 1\nSMS 0 cs 24 1 0 0 0\n"
            "SMS_STATE 1 submitted 78 0\nSMS_STATE 1 sent 78 0\n"
            "SMS_REPORT 0 cs 78 64\nSTATUS\n"
        )
        self.assertIn("sms1=failed,cs,sub0,gen0,bytes24,ref78,error64", failed.stdout)

    def test_incoming_sms_keeps_transport_storage_and_reference(self) -> None:
        result = self.replay(
            "SUB 1 1 1 1\nSMS_IN 1 cs 88 sim 19\nSTATUS\n"
        )
        self.assertIn("sms-in-result=0 id=1", result.stdout)
        self.assertIn("sms1=received,cs,sub1,gen0,bytes88,ref19", result.stdout)

    def test_ims_call_audio_dtmf_hold_and_end(self) -> None:
        result = self.replay(
            "SUB 0 1 1 1\nIMS 0 registered lte 31 0\n"
            "DIAL 0 auto 0 0 +32000000000\n"
            "CALL_STATE 1 alerting\nCALL_STATE 1 active\n"
            "AUDIO 1 1\nDTMF 1 5\nCALL_STATE 1 held\n"
            "DTMF 1 5\nCALL_STATE 1 active\nCALL_STATE 1 disconnecting\n"
            "CALL_STATE 1 ended\nSTATUS\n"
        )
        self.assertIn("dial-result=0 id=1", result.stdout)
        self.assertIn("dtmf-result=0", result.stdout)
        self.assertIn("dtmf-result=-71", result.stdout)
        self.assertIn("call1=ended,ims", result.stdout)

    def test_emergency_fallback_and_video_requirements(self) -> None:
        emergency = self.replay(
            "SUB 0 1 0 1\nDIAL 0 auto 1 0 112\nSTATUS\n"
        )
        self.assertIn("dial-result=0 id=1", emergency.stdout)
        self.assertIn("call1=dialing,cs,sub0,gen0,remote0,emergency1", emergency.stdout)

        video = self.replay("SUB 0 1 1 1\nDIAL 0 auto 0 1 +32000000000\n")
        self.assertIn("dial-result=-95 id=0", video.stdout)

    def test_supplementary_and_ssr_clear_runtime_without_losing_slot(self) -> None:
        result = self.replay(
            "SUB 0 1 1 1\nIMS 0 registered wlan 31 0\nSUPP 0 1 1 2\n"
            "SMS 0 auto 24 1 0 0 0\nSMS_STATE 1 submitted 7 0\n"
            "DIAL 0 auto 0 0 +32000000000\nCALL_STATE 1 active\nAUDIO 1 1\n"
            "SSR\nSTATUS\n"
        )
        self.assertIn("ssr-generation=1", result.stdout)
        self.assertIn("sub0=cs0,emergency1,ims-none", result.stdout)
        self.assertIn("cw1,clip1,clir2", result.stdout)
        self.assertIn("sms1=failed,ims,sub0,gen0,bytes24,ref7,error102", result.stdout)
        self.assertIn("call1=ended,ims,sub0,gen0", result.stdout)
        self.assertIn("audio0", result.stdout)

    def test_mo_call_binds_one_remote_identity(self) -> None:
        result = self.replay(
            "SUB 0 1 1 1\nDIAL 0 cs 0 0 +32000000000\n"
            "BIND 1 9\nBIND 1 9\nBIND 1 10\nSTATUS\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bind-result=0", result.stdout)
        self.assertIn("bind-result=-114", result.stdout)
        self.assertIn("bind-result=-16", result.stdout)
        self.assertIn("call1=dialing,cs,sub0,gen0,remote9", result.stdout)

    def test_complete_snapshot_can_replace_all_calls_and_is_subscription_scoped(self) -> None:
        source = r'''#include "hotdog-telephony.h"
#include <stdio.h>
#include <string.h>
static void fill(struct hotdog_call_observation *o,unsigned sub,unsigned base) {
 size_t i; memset(o,0,sizeof(*o)*HOTDOG_TELEPHONY_MAX_CALLS);
 for(i=0;i<HOTDOG_TELEPHONY_MAX_CALLS;i++) { o[i].remote_id=base+i;
  o[i].subscription=sub; o[i].transport=HOTDOG_TRANSPORT_CS;
  o[i].direction=HOTDOG_CALL_MT; o[i].state=HOTDOG_CALL_INCOMING; }
}
int main(void) { struct hotdog_telephony t; struct hotdog_call_observation o[8];
 struct hotdog_call_changes c; size_t i; hotdog_telephony_init(&t);
 hotdog_telephony_set_subscription(&t,0,true,true,true);
 hotdog_telephony_set_subscription(&t,1,true,true,true);
 fill(o,0,1); if(hotdog_call_reconcile(&t,0,o,8,&c)) return 1;
 printf("first=%zu ",c.count); fill(o,0,9);
 if(hotdog_call_reconcile(&t,0,o,8,&c)) return 2;
 printf("replace=%zu ids=",c.count);
 for(i=0;i<8;i++) printf("%u%s",t.calls[i].remote_id,i==7?" ":",");
 if(hotdog_call_reconcile(&t,0,NULL,0,&c)) return 3;
 printf("empty=%zu ",c.count); memset(o,0,sizeof(o)); o[0].remote_id=1;
 o[0].subscription=1; o[0].transport=HOTDOG_TRANSPORT_CS;
 o[0].direction=HOTDOG_CALL_MT; o[0].state=HOTDOG_CALL_INCOMING;
 if(hotdog_call_reconcile(&t,1,o,1,&c)) return 4;
 if(hotdog_call_reconcile(&t,0,NULL,0,&c)) return 5;
 printf("sub1=%s remote=%u\n",hotdog_call_state_name(t.calls[0].state),t.calls[0].remote_id);
}
'''
        cfile = Path(self._temporary.name) / "snapshot.c"
        binary = Path(self._temporary.name) / "snapshot"
        cfile.write_text(source)
        subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", str(SOURCE), str(SOURCE / "hotdog-telephony.c"),
             str(cfile), "-o", str(binary)],
            check=True,
        )
        output = subprocess.run([str(binary)], check=True, capture_output=True,
                                text=True).stdout.strip()
        self.assertEqual(
            output,
            "first=8 replace=16 ids=9,10,11,12,13,14,15,16 empty=8 "
            "sub1=incoming remote=1",
        )

    def test_invalid_number_and_input_fail_closed(self) -> None:
        invalid_number = self.replay("SUB 0 1 1 1\nDIAL 0 cs 0 0 not-a-number\n")
        self.assertIn("dial-result=-22 id=0", invalid_number.stdout)

        malformed = self.replay("IMS 0 registered lte\n")
        self.assertEqual(malformed.returncode, 2)
        self.assertIn("line 1", malformed.stderr)


if __name__ == "__main__":
    unittest.main()
