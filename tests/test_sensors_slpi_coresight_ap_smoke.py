#!/usr/bin/env python3
"""Offline fixture tests for sensors-slpi-coresight-ap-smoke.sh."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/sensors-slpi-coresight-ap-smoke.sh"
VERMAGIC = "6.16.0-sm8150 SMP preempt mod_unload aarch64"


class Fixture:
    def __init__(self, test: unittest.TestCase):
        self.test = test
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.sysfs = self.root / "sys"
        self.configfs = self.root / "config"
        self.dev = self.root / "dev"
        self.proc_modules = self.root / "proc_modules"
        self.bin = self.root / "bin"
        self.module = self.root / "stm_p_basic.ko"
        self.capture = self.root / "capture.bin"
        self.env = os.environ.copy()

        self._build_tree()
        self._build_fake_commands()
        self.module.write_bytes(b"fake reviewed stm_p_basic module\n")
        self.module_sha = hashlib.sha256(self.module.read_bytes()).hexdigest()

        self.env.update({
            "PATH": f"{self.bin}:{self.env['PATH']}",
            "HOTDOG_AP_SMOKE_SYSFS_ROOT": str(self.sysfs),
            "HOTDOG_AP_SMOKE_CONFIGFS_ROOT": str(self.configfs),
            "HOTDOG_AP_SMOKE_DEV_ROOT": str(self.dev),
            "HOTDOG_AP_SMOKE_PROC_MODULES": str(self.proc_modules),
            "FAKE_MODINFO_VERMAGIC": VERMAGIC,
        })

    def cleanup(self):
        self.tmp.cleanup()

    def _write(self, path: Path, data: str):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)

    def _build_tree(self):
        self._write(self.sysfs / "bus/coresight/devices/stm0/enable_source",
                    "0\n")
        self._write(self.sysfs / "bus/coresight/devices/stm0/status",
                    "stm-ok\n")
        self._write(self.sysfs / "bus/coresight/devices/tmc_etf0/enable_sink",
                    "0\n")
        self._write(self.sysfs / "bus/coresight/devices/tmc_etf0/status",
                    "etf-ok\n")
        self._write(self.sysfs / "bus/coresight/devices/tmc_etf0/mgmt/rsz",
                    "0x1000\n")
        self._write(self.sysfs / "class/stm/stm0/masters", "0 0\n")
        self._write(self.sysfs / "class/stm/stm0/channels", "16\n")
        (self.configfs / "stp-policy").mkdir(parents=True)
        self._write(self.dev / "stm0", "")
        self._write(self.dev / "tmc_etf0", "TRACEBYTES")
        self._write(self.proc_modules, "")

    def _build_fake_commands(self):
        self.bin.mkdir(parents=True)
        commands = {
            "hostname": "#!/usr/bin/env bash\nprintf 'hotdog\\n'\n",
            "uname": textwrap.dedent("""\
                #!/usr/bin/env bash
                case "$1" in
                -m) printf 'aarch64\\n' ;;
                -r) printf '6.16.0-sm8150\\n' ;;
                *) exit 2 ;;
                esac
                """),
            "modinfo": textwrap.dedent("""\
                #!/usr/bin/env bash
                if [ "$1" = "-F" ] && [ "$2" = "vermagic" ]; then
                  printf '%s\\n' "${FAKE_MODINFO_VERMAGIC:-bad}"
                  exit 0
                fi
                exit 2
                """),
            "modprobe": textwrap.dedent("""\
                #!/usr/bin/env bash
                modules=${HOTDOG_AP_SMOKE_PROC_MODULES:?}
                if [ "$1" = "-r" ]; then
                  name=$2
                  tmp="${modules}.tmp"
                  awk -v name="$name" '$1 != name' "$modules" > "$tmp"
                  mv "$tmp" "$modules"
                  exit 0
                fi
                name=$1
                if ! awk -v name="$name" '$1 == name { found = 1 } END { exit !found }' "$modules"; then
                  printf '%s 1 0 - Live 0x0\\n' "$name" >> "$modules"
                fi
                """),
            "insmod": textwrap.dedent("""\
                #!/usr/bin/env bash
                modules=${HOTDOG_AP_SMOKE_PROC_MODULES:?}
                if ! awk '$1 == "stm_p_basic" { found = 1 } END { exit !found }' "$modules"; then
                  printf 'stm_p_basic 1 0 - Live 0x0\\n' >> "$modules"
                fi
                """),
            "find": textwrap.dedent("""\
                #!/usr/bin/env bash
                for arg in "$@"; do
                  if [ "$arg" = "-""printf" ]; then
                    printf 'fake BusyBox find: unsupported option\\n' >&2
                    exit 64
                  fi
                done
                if [ "$#" -ne 2 ] || [ "$2" != "-print" ]; then
                  printf 'fake BusyBox find: unsupported arguments: %s\\n' "$*" >&2
                  exit 64
                fi
                root=$1
                walk() {
                  dir=$1
                  printf '%s\\n' "$dir"
                  for child in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
                    [ -e "$child" ] || [ -L "$child" ] || continue
                    if [ -d "$child" ]; then
                      walk "$child"
                    else
                      printf '%s\\n' "$child"
                    fi
                  done
                }
                walk "$root"
                """),
        }
        for name, body in commands.items():
            path = self.bin / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def run(self, *extra: str, env: dict[str, str] | None = None):
        run_env = self.env.copy()
        if env:
            run_env.update(env)
        args = [
            str(SCRIPT),
            "--module", str(self.module),
            "--module-sha256", self.module_sha,
            "--sink", "tmc_etf0",
            "--capture-out", str(self.capture),
            *extra,
        ]
        return subprocess.run(args, cwd=ROOT, env=run_env, text=True,
                              capture_output=True, timeout=10)

    def modules(self):
        return self.proc_modules.read_text()


class SensorsSlpiCoreSightApSmokeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture(self)

    def tearDown(self):
        self.fixture.cleanup()

    def test_success_rolls_back_introduced_state(self):
        result = self.fixture.run()

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(
            (self.fixture.sysfs /
             "bus/coresight/devices/stm0/enable_source").read_text(), "0\n")
        self.assertEqual(
            (self.fixture.sysfs /
             "bus/coresight/devices/tmc_etf0/enable_sink").read_text(), "0\n")
        self.assertFalse(
            (self.fixture.configfs /
             "stp-policy/stm0:p_basic.ap-smoke").exists())
        self.assertEqual(self.fixture.modules(), "")
        self.assertEqual(self.fixture.capture.read_bytes(), b"TRACEBYTES")
        self.assertIn("HOTDOG_STM_AP_SMOKE", (self.fixture.dev /
                                              "stm0").read_text())

    def test_busybox_find_fixture_rejects_formatted_output(self):
        forbidden = "-" + "printf"

        self.assertNotIn(forbidden, SCRIPT.read_text())

        rejected = subprocess.run([
            str(self.fixture.bin / "find"),
            str(self.fixture.sysfs),
            forbidden,
        ], text=True, capture_output=True, timeout=10)
        result = self.fixture.run()

        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_preexisting_modules_are_not_unloaded(self):
        self.fixture.proc_modules.write_text(
            "stm_core 1 0 - Live 0x0\n"
            "stm_p_basic 1 0 - Live 0x0\n")

        result = self.fixture.run()

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("stm_core", self.fixture.modules())
        self.assertIn("stm_p_basic", self.fixture.modules())

    def test_wrong_hash_is_rejected_before_loading_modules(self):
        result = subprocess.run([
            str(SCRIPT),
            "--module", str(self.fixture.module),
            "--module-sha256", "0" * 64,
            "--sink", "tmc_etf0",
            "--capture-out", str(self.fixture.capture),
        ], cwd=ROOT, env=self.fixture.env, text=True, capture_output=True,
           timeout=10)

        self.assertEqual(result.returncode, 1)
        self.assertIn("module sha256 mismatch", result.stderr)
        self.assertEqual(self.fixture.modules(), "")

    def test_wrong_vermagic_is_rejected(self):
        result = self.fixture.run(env={"FAKE_MODINFO_VERMAGIC": "bad"})

        self.assertEqual(result.returncode, 1)
        self.assertIn("module vermagic mismatch", result.stderr)
        self.assertEqual(self.fixture.modules(), "")

    def test_ambiguous_stm_devices_are_rejected_and_modules_rolled_back(self):
        self.fixture._write(
            self.fixture.sysfs /
            "bus/coresight/devices/stm1/enable_source", "0\n")

        result = self.fixture.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("expected exactly one CoreSight stm0", result.stderr)
        self.assertEqual(self.fixture.modules(), "")

    def test_etr_sink_is_rejected(self):
        self.fixture._write(
            self.fixture.sysfs /
            "bus/coresight/devices/tmc_etr0/enable_sink", "0\n")
        self.fixture._write(
            self.fixture.sysfs /
            "bus/coresight/devices/tmc_etr0/buffer_size", "4096\n")
        self.fixture._write(self.fixture.dev / "tmc_etr0", "ETR")

        result = subprocess.run([
            str(SCRIPT),
            "--module", str(self.fixture.module),
            "--module-sha256", self.fixture.module_sha,
            "--sink", "tmc_etr0",
            "--capture-out", str(self.fixture.capture),
        ], cwd=ROOT, env=self.fixture.env, text=True, capture_output=True,
           timeout=10)

        self.assertEqual(result.returncode, 1)
        self.assertIn("sink is not an unambiguous ETF candidate", result.stderr)
        self.assertEqual(self.fixture.modules(), "")

    def test_pre_enabled_source_is_refused_without_disabling_it(self):
        source = self.fixture.sysfs / "bus/coresight/devices/stm0/enable_source"
        source.write_text("1\n")

        result = self.fixture.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("STM source already enabled", result.stderr)
        self.assertEqual(source.read_text(), "1\n")

    def test_missing_policy_backend_rolls_back_modules(self):
        (self.fixture.configfs / "stp-policy").rmdir()

        result = self.fixture.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("missing STM configfs policy root", result.stderr)
        self.assertEqual(self.fixture.modules(), "")

    def test_trap_rolls_back_after_policy_creation_failure(self):
        channels = self.fixture.sysfs / "class/stm/stm0/channels"
        channels.write_text("10\n")

        result = self.fixture.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("does not expose channel 10", result.stderr)
        self.assertEqual(self.fixture.modules(), "")
        self.assertFalse(
            (self.fixture.configfs /
             "stp-policy/stm0:p_basic.ap-smoke").exists())

    def test_capture_failure_triggers_full_rollback(self):
        (self.fixture.dev / "tmc_etf0").unlink()

        result = self.fixture.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("missing ETF devfs node", result.stderr)
        self.assertEqual(self.fixture.modules(), "")
        self.assertEqual(
            (self.fixture.sysfs /
             "bus/coresight/devices/tmc_etf0/enable_sink").read_text(), "0\n")

    def test_dd_failure_after_enable_triggers_full_rollback(self):
        (self.fixture.dev / "tmc_etf0").unlink()
        (self.fixture.dev / "tmc_etf0").mkdir()

        result = self.fixture.run()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.fixture.modules(), "")
        self.assertFalse(
            (self.fixture.configfs /
             "stp-policy/stm0:p_basic.ap-smoke").exists())
        self.assertEqual(
            (self.fixture.sysfs /
             "bus/coresight/devices/stm0/enable_source").read_text(), "0\n")
        self.assertEqual(
            (self.fixture.sysfs /
             "bus/coresight/devices/tmc_etf0/enable_sink").read_text(), "0\n")

    def test_term_trap_after_enable_triggers_full_rollback(self):
        timeout = self.fixture.bin / "timeout"
        timeout.write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            kill -TERM "$PPID"
            sleep 1
            """))
        timeout.chmod(timeout.stat().st_mode | stat.S_IXUSR)

        result = self.fixture.run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("received TERM, rolling back", result.stderr)
        self.assertEqual(self.fixture.modules(), "")
        self.assertFalse(
            (self.fixture.configfs /
             "stp-policy/stm0:p_basic.ap-smoke").exists())
        self.assertEqual(
            (self.fixture.sysfs /
             "bus/coresight/devices/stm0/enable_source").read_text(), "0\n")
        self.assertEqual(
            (self.fixture.sysfs /
             "bus/coresight/devices/tmc_etf0/enable_sink").read_text(), "0\n")


if __name__ == "__main__":
    unittest.main()
