#!/usr/bin/env python3
"""Offline fixture tests for sensors-slpi-coresight-ap-smoke.sh."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
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
        self.command_log = self.root / "commands.log"
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
            "FAKE_COMMAND_LOG": str(self.command_log),
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
        self._write(self.sysfs / "bus/coresight/devices/tmc_etf0/buffer_size",
                    "0x10000\n")
        self._write(self.sysfs / "bus/coresight/devices/tmc_etf0/status",
                    "etf-ok\n")
        self._write(self.sysfs / "bus/coresight/devices/tmc_etf0/mgmt/rsz",
                    "0x1000\n")
        self._write(self.sysfs / "bus/coresight/devices/stm0/connections/out:0",
                    "")
        self._write(
            self.sysfs /
            "bus/coresight/devices/tmc_etf0/connections/in:0", "")
        self._write(self.sysfs / "class/stm/stm0/masters", "0 0\n")
        self._write(self.sysfs / "class/stm/stm0/channels", "16\n")
        (self.configfs / "stp-policy").mkdir(parents=True)
        self._write(self.dev / "stm0", "")
        self._write(self.dev / "tmc_etf0", "TRACEBYTES")
        self._write(self.proc_modules, "")
        self._write(self.command_log, "")

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
                log=${FAKE_COMMAND_LOG:?}
                printf 'modprobe %s\\n' "$*" >> "$log"
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
                if [ "$name" = "stm_core" ] && [ "${FAKE_MODPROBE_CREATES_TOPOLOGY:-0}" = 1 ]; then
                  sys=${HOTDOG_AP_SMOKE_SYSFS_ROOT:?}
                  mkdir -p "$sys/bus/coresight/devices/stm0/connections"
                  mkdir -p "$sys/bus/coresight/devices/tmc_etf0/connections"
                  mkdir -p "$sys/bus/coresight/devices/tmc_etf0/mgmt"
                  mkdir -p "$sys/class/stm/stm0"
                  printf '0\\n' > "$sys/bus/coresight/devices/stm0/enable_source"
                  printf 'stm-ok\\n' > "$sys/bus/coresight/devices/stm0/status"
                  printf '0\\n' > "$sys/bus/coresight/devices/tmc_etf0/enable_sink"
                  printf '0x10000\\n' > "$sys/bus/coresight/devices/tmc_etf0/buffer_size"
                  printf 'etf-ok\\n' > "$sys/bus/coresight/devices/tmc_etf0/status"
                  printf '0x1000\\n' > "$sys/bus/coresight/devices/tmc_etf0/mgmt/rsz"
                  : > "$sys/bus/coresight/devices/stm0/connections/out:0"
                  : > "$sys/bus/coresight/devices/tmc_etf0/connections/in:0"
                  printf '0 0\\n' > "$sys/class/stm/stm0/masters"
                  printf '16\\n' > "$sys/class/stm/stm0/channels"
                fi
                """),
            "insmod": textwrap.dedent("""\
                #!/usr/bin/env bash
                modules=${HOTDOG_AP_SMOKE_PROC_MODULES:?}
                log=${FAKE_COMMAND_LOG:?}
                printf 'insmod %s\\n' "$*" >> "$log"
                if ! awk '$1 == "stm_p_basic" { found = 1 } END { exit !found }' "$modules"; then
                  printf 'stm_p_basic 1 0 - Live 0x0\\n' >> "$modules"
                fi
                """),
            "lsmod": textwrap.dedent("""\
                #!/usr/bin/env bash
                printf 'Module Size Used by\\n'
                cat "${HOTDOG_AP_SMOKE_PROC_MODULES:?}"
                """),
            "rmmod": textwrap.dedent("""\
                #!/usr/bin/env bash
                modules=${HOTDOG_AP_SMOKE_PROC_MODULES:?}
                log=${FAKE_COMMAND_LOG:?}
                name=$1
                printf 'rmmod %s\\n' "$name" >> "$log"
                if [ "${FAKE_RMMOD_FAIL:-0}" = 1 ]; then
                  printf 'fake rmmod failure for %s\\n' "$name" >&2
                  exit 1
                fi
                tmp="${modules}.tmp"
                awk -v name="$name" '$1 != name' "$modules" > "$tmp"
                mv "$tmp" "$modules"
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

    def commands(self):
        return self.command_log.read_text()

    def command_lines(self):
        return [line for line in self.commands().splitlines() if line]

    def remove_coresight_topology(self):
        shutil.rmtree(self.sysfs / "bus", ignore_errors=True)
        shutil.rmtree(self.sysfs / "class", ignore_errors=True)


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
        self.assertIn("sink-buffer-size: 0x10000", result.stdout)
        self.assertIn("sink-buffer-size-post: 0x10000", result.stdout)
        self.assertIn("rmmod stm_p_basic", self.fixture.commands())
        self.assertNotIn("modprobe -r stm_p_basic", self.fixture.commands())
        self.assertNotIn("modprobe stm_core", self.fixture.commands())

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
        self.assertNotIn("rmmod stm_p_basic", self.fixture.commands())
        self.assertNotIn("modprobe -r stm_core", self.fixture.commands())

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

    def test_ambiguous_stm_devices_are_rejected_before_module_load(self):
        self.fixture._write(
            self.fixture.sysfs /
            "bus/coresight/devices/stm1/enable_source", "0\n")

        result = self.fixture.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("expected exactly one CoreSight stm0", result.stderr)
        self.assertEqual(self.fixture.modules(), "")
        self.assertEqual(self.fixture.commands(), "")

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
        self.assertIn("refusing ETR sink", result.stderr)
        self.assertEqual(self.fixture.modules(), "")
        self.assertEqual(self.fixture.commands(), "")

    def test_invalid_sink_argument_is_rejected_before_module_load(self):
        result = subprocess.run([
            str(SCRIPT),
            "--module", str(self.fixture.module),
            "--module-sha256", self.fixture.module_sha,
            "--sink", "tmc_funnel0",
            "--capture-out", str(self.fixture.capture),
        ], cwd=ROOT, env=self.fixture.env, text=True, capture_output=True,
           timeout=10)

        self.assertEqual(result.returncode, 1)
        self.assertIn("sink must be a tmc_etf* device", result.stderr)
        self.assertEqual(self.fixture.modules(), "")
        self.assertEqual(self.fixture.commands(), "")

    def test_ambiguous_etf_sink_is_rejected(self):
        self.fixture._write(
            self.fixture.sysfs /
            "bus/coresight/devices/tmc_etf1/enable_sink", "0\n")
        self.fixture._write(
            self.fixture.sysfs /
            "bus/coresight/devices/tmc_etf1/buffer_size", "0x10000\n")
        self.fixture._write(self.fixture.dev / "tmc_etf1", "TRACE2")

        result = self.fixture.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("expected exactly one explicit ETF sink candidate",
                      result.stderr)
        self.assertEqual(self.fixture.modules(), "")
        self.assertEqual(self.fixture.commands(), "")

    def test_absent_topology_loads_core_then_enumerates_before_p_basic(self):
        self.fixture.remove_coresight_topology()

        result = self.fixture.run(env={"FAKE_MODPROBE_CREATES_TOPOLOGY": "1"})

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("coresight-enumeration-phase: pre-load", result.stdout)
        self.assertIn("coresight-topology-state: absent", result.stdout)
        self.assertIn("coresight-enumeration-phase: post-stm-core-load",
                      result.stdout)
        lines = self.fixture.command_lines()
        self.assertEqual(lines[0], "modprobe stm_core")
        self.assertTrue(lines[1].startswith("insmod "))
        self.assertEqual(lines[-2:], ["rmmod stm_p_basic",
                                      "modprobe -r stm_core"])
        self.assertEqual(self.fixture.modules(), "")

    def test_absent_topology_rolls_back_core_without_p_basic(self):
        self.fixture.remove_coresight_topology()

        result = self.fixture.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("missing CoreSight sysfs topology", result.stderr)
        self.assertEqual(self.fixture.command_lines(), [
            "modprobe stm_core",
            "modprobe -r stm_core",
        ])
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

    def test_rmmod_failure_leaves_nonzero_diagnostic(self):
        result = self.fixture.run(env={"FAKE_RMMOD_FAIL": "1"})

        self.assertEqual(result.returncode, 1)
        self.assertIn("fake rmmod failure for stm_p_basic", result.stderr)
        self.assertIn("ERROR: rmmod stm_p_basic failed", result.stderr)
        self.assertIn("ERROR: rollback verification failed", result.stderr)
        self.assertIn("stm_p_basic", self.fixture.modules())
        self.assertEqual(
            (self.fixture.sysfs /
             "bus/coresight/devices/stm0/enable_source").read_text(), "0\n")
        self.assertEqual(
            (self.fixture.sysfs /
             "bus/coresight/devices/tmc_etf0/enable_sink").read_text(), "0\n")

    def test_absent_insmod_module_at_cleanup_is_success(self):
        timeout = self.fixture.bin / "timeout"
        timeout.write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            modules=${HOTDOG_AP_SMOKE_PROC_MODULES:?}
            tmp="${modules}.tmp"
            awk '$1 != "stm_p_basic"' "$modules" > "$tmp"
            mv "$tmp" "$modules"
            shift
            input=
            output=
            for arg in "$@"; do
              case "$arg" in
              if=*) input=${arg#if=} ;;
              of=*) output=${arg#of=} ;;
              esac
            done
            cp "$input" "$output"
            """))
        timeout.chmod(timeout.stat().st_mode | stat.S_IXUSR)

        result = self.fixture.run()

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.fixture.modules(), "")
        self.assertNotIn("rmmod stm_p_basic", self.fixture.commands())

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
