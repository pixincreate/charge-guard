# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="battery-guard-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.state = self.home / "state"
        self.module = self.home / "module"
        self.state.mkdir(mode=0o700)
        self.module.mkdir()
        (self.module / "module.prop").write_text("id=fixture\nversion=1\ndescription=Original\n")
        for name, value in {"soc": "69", "present": "1", "temp": "330", "boot": "boot-a",
                            "fcc": "2900000", "mode": "444", "enabled": "1"}.items():
            (self.home / name).write_text(value)
        # Use native system calls where these command-line tools are absent on macOS.
        self.executable("setsid", f"#!{sys.executable}\nimport os, sys\nos.setsid()\nos.execvp(sys.argv[1], sys.argv[1:])\n")
        self.executable("flock", f'''#!{sys.executable}
import fcntl, os, sys, time
args = sys.argv[1:]
deadline = time.monotonic() if args[0] == '-n' else float('inf')
fd = int(args[-1])
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.monotonic() >= deadline:
            sys.exit(1)
        time.sleep(0.02)
''')
        self.driver = self.executable("driver", f'''#!{sys.executable}
from pathlib import Path
import json, os, sys, time
p = Path(os.environ['FIXTURE'])
op = sys.argv[1]
if op in ['snapshot', 'acquire', 'charge'] and (p / 'delay').exists(): time.sleep(1.3)
def read(name): return (p / name).read_text().strip()
def put(name, value): (p / name).write_text(str(value))
def event(value):
    with (p / 'events').open('a') as out: out.write(value + '\\n')
if op == 'clock': print(int(time.monotonic()))
elif op == 'boot': print(read('boot'))
elif op == 'compatible': sys.exit(int((p / 'unsupported').exists()))
elif op == 'sensors':
    if (p / 'sensor-failure').exists(): sys.exit(1)
    print(read('soc'), read('present'), read('present'), read('temp'))
elif op == 'snapshot':
    Path(sys.argv[2]).write_text(json.dumps({{k: read(k) for k in ['fcc', 'mode', 'enabled', 'boot']}}))
elif op in ['acquire', 'hold', 'charge']:
    if op == 'hold' and (p / 'slow').exists():
        put('child-started', os.getpid())
        time.sleep(4)
        event('delayed-write')
    put('mode', '644')
    if (p / 'partial-write').exists(): sys.exit(1)
    put('fcc', '2900000' if op == 'charge' else '0')
    put('mode', '444')
    if op == 'acquire': put('enabled', '0')
    event(op)
elif op == 'policy': sys.exit(int(read('enabled') != '0'))
elif op == 'recover':
    if (p / 'fail-recovery').exists(): sys.exit(1)
    snapshot = json.loads(Path(sys.argv[2]).read_text())
    if snapshot['boot'] == read('boot'): put('fcc', '0')
    put('enabled', snapshot['enabled'])
    suspended = '1' if int(read('soc')) >= 70 and read('present') == '1' and not (p / 'stuck-input').exists() else '0'
    import subprocess
    ready = subprocess.run(['sh', {str(ROOT / 'recovery-ready.sh')!r}, read('soc'), read('present'), suspended, '70'])
    if ready.returncode: sys.exit(1)
    if snapshot['boot'] == read('boot'): put('fcc', snapshot['fcc'])
    put('mode', snapshot['mode'])
    event('recover')
else: sys.exit(2)
''')
        self.environment = dict(os.environ, FIXTURE=str(self.home), PATH=f"{self.home}:{os.environ['PATH']}")
        self.processes = []
        self.addCleanup(self.stop_processes)

    def executable(self, name, content):
        path = self.home / name
        path.write_text(content)
        path.chmod(0o700)
        return path

    def start(self):
        process = subprocess.Popen(
            ["sh", str(ROOT / "runtime.sh"), "supervise", str(self.state), str(self.driver),
             str(self.module), "1", "3"], env=self.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
        )
        self.processes.append(process)
        return process

    def stop_processes(self):
        (self.state / "stop").touch()
        for process in self.processes:
            if process.poll() is None:
                (self.state / "stop").touch()
                try:
                    process.communicate(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()

    def wait_for(self, condition, seconds=12):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.05)
        diagnostics = (self.state / "status").read_text() if (self.state / "status").exists() else "no status"
        self.fail(diagnostics)

    def value(self, name):
        return (self.home / name).read_text().strip()

    def status(self, value):
        path = self.state / "status"
        return path.exists() and path.read_text().strip() == value

    def finish(self, process):
        (self.state / "stop").touch()
        output = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, output)
        self.assertEqual(self.value("fcc"), "2900000")
        self.assertEqual(self.value("enabled"), "1")
        self.assertEqual(self.value("mode"), "444")
        self.assertFalse((self.state / "journal").exists())

    def test_charge_hold_and_resume_boundaries(self):
        process = self.start()
        self.wait_for(lambda: self.status("Charging"))
        self.assertEqual(self.value("enabled"), "0")
        (self.home / "soc").write_text("70")
        self.wait_for(lambda: self.status("Holding"))
        self.assertEqual(self.value("fcc"), "0")
        self.assertEqual(self.value("mode"), "444")
        (self.home / "soc").write_text("66")
        time.sleep(2)
        self.assertEqual(self.value("fcc"), "0")
        (self.home / "soc").write_text("65")
        self.wait_for(lambda: self.status("Charging"))
        self.finish(process)

    def test_module_card_follows_verified_states_and_stop(self):
        process = self.start()
        props = self.module / "module.prop"
        self.wait_for(lambda: "[Charging] Last reported:" in props.read_text())
        unchanged = props.stat().st_mtime_ns
        time.sleep(2)
        self.assertEqual(props.stat().st_mtime_ns, unchanged)
        (self.home / "soc").write_text("70")
        self.wait_for(lambda: "[Holding] Last reported:" in props.read_text())
        self.assertEqual(self.value("fcc"), "0")
        self.finish(process)
        self.assertIn("[Stopped] Last reported:", props.read_text())

    def test_display_failure_does_not_stop_charging_control(self):
        (self.module / "module.prop").write_text("id=fixture\ndescription=One\ndescription=Two\n")
        process = self.start()
        self.wait_for(lambda: self.status("Charging"))
        self.assertFalse((self.state / "fault").exists())
        self.finish(process)

    def test_action_duration_advances_within_state_and_resets_on_transition(self):
        process = self.start()
        self.wait_for(lambda: self.status("Charging"))

        def report_duration(phase):
            result = subprocess.run(
                ["sh", str(ROOT / "display.sh"), "report", str(self.state), str(self.module), str(self.driver)],
                env=self.environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("State: " + phase, result.stdout)
            duration = next(line for line in result.stdout.splitlines() if line.startswith("State duration:"))
            self.assertNotIn("Unavailable", duration)
            return int(duration.split()[2])

        first = report_duration("Charging")
        time.sleep(3)
        elapsed = report_duration("Charging")
        self.assertGreaterEqual(elapsed, first + 3)
        (self.home / "soc").write_text("70")
        self.wait_for(lambda: self.status("Holding"))
        self.assertLess(report_duration("Holding"), elapsed)
        self.finish(process)

    def test_unplug_releases_and_replug_acquires_again(self):
        (self.home / "soc").write_text("70")
        process = self.start()
        self.wait_for(lambda: self.status("Holding"))
        (self.home / "present").write_text("0")
        self.wait_for(lambda: self.status("Released"))
        self.assertEqual(self.value("fcc"), "2900000")
        self.assertEqual(self.value("enabled"), "1")
        (self.home / "present").write_text("1")
        self.wait_for(lambda: self.status("Holding"))
        self.assertEqual(self.value("fcc"), "0")
        self.finish(process)

    def test_temperature_fault_restores_and_latches(self):
        process = self.start()
        self.wait_for(lambda: self.status("Charging"))
        (self.home / "temp").write_text("400")
        process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.value("fcc"), "2900000")
        self.assertEqual(self.value("enabled"), "1")
        self.assertTrue((self.state / "fault").exists())
        self.assertIn("[Fault] Last reported:", (self.module / "module.prop").read_text())
        before = (self.home / "events").read_text()
        retry = self.start()
        retry.communicate(timeout=10)
        self.assertNotEqual(retry.returncode, 0)
        self.assertEqual((self.home / "events").read_text(), before)

    def test_missing_sensor_restores(self):
        process = self.start()
        self.wait_for(lambda: self.status("Charging"))
        (self.home / "sensor-failure").touch()
        process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.value("enabled"), "1")
        self.assertEqual(self.value("mode"), "444")

    def test_controller_death_waits_for_inherited_writer_lock(self):
        process = self.start()
        self.wait_for(lambda: self.status("Charging"))
        (self.home / "slow").touch()
        (self.home / "soc").write_text("70")
        self.wait_for(lambda: (self.home / "child-started").exists())
        pid = int((self.state / "controller.pid").read_text())
        os.kill(pid, signal.SIGKILL)
        time.sleep(0.5)
        self.assertNotIn("recover", (self.home / "events").read_text())
        process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.value("fcc"), "2900000")
        self.assertEqual(self.value("enabled"), "1")
        events = (self.home / "events").read_text().splitlines()
        self.assertLess(events.index("delayed-write"), events.index("recover"))
        time.sleep(1)
        self.assertEqual(self.value("fcc"), "2900000")

    def test_guard_death_triggers_controller_recovery(self):
        (self.home / "soc").write_text("70")
        process = self.start()
        self.wait_for(lambda: self.status("Holding"))
        process.kill()
        process.communicate(timeout=5)
        self.wait_for(lambda: (self.state / "fault").exists())
        self.assertEqual(self.value("fcc"), "2900000")
        self.assertEqual(self.value("enabled"), "1")
        self.assertFalse((self.state / "journal").exists())

    def test_failed_recovery_retains_journal_and_reports_fault(self):
        process = self.start()
        self.wait_for(lambda: self.status("Charging"))
        (self.home / "fail-recovery").touch()
        (self.home / "temp").write_text("400")
        process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        self.assertTrue((self.state / "journal").exists())
        self.assertTrue(self.status("Fault"))

    def test_pending_reboot_recovery_precedes_unsupported_build_rejection(self):
        import json
        (self.state / "journal").write_text(json.dumps({"fcc": "2900000", "mode": "444",
                                                       "enabled": "1", "boot": "old-boot"}))
        (self.home / "enabled").write_text("0")
        (self.home / "fcc").write_text("1800000")
        (self.home / "unsupported").touch()
        process = self.start()
        process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.value("enabled"), "1")
        self.assertEqual(self.value("fcc"), "1800000")
        self.assertFalse((self.state / "journal").exists())

    def test_remove_marker_restores_without_a_fault(self):
        process = self.start()
        self.wait_for(lambda: self.status("Charging"))
        (self.module / "remove").touch()
        output = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, output)
        self.assertEqual(self.value("enabled"), "1")
        self.assertEqual(self.value("fcc"), "2900000")
        self.assertFalse((self.state / "fault").exists())

    def test_stalled_controller_is_recovered_by_the_guard(self):
        (self.home / "soc").write_text("70")
        process = self.start()
        self.wait_for(lambda: self.status("Holding"))
        pid = int((self.state / "controller.pid").read_text())
        os.kill(pid, signal.SIGSTOP)
        process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.value("fcc"), "2900000")
        self.assertEqual(self.value("enabled"), "1")
        self.assertFalse((self.state / "journal").exists())

    def test_partial_write_restores_permissions_and_policy(self):
        process = self.start()
        self.wait_for(lambda: self.status("Charging"))
        (self.home / "partial-write").touch()
        (self.home / "soc").write_text("70")
        process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.value("mode"), "444")
        self.assertEqual(self.value("enabled"), "1")

    def test_unknown_build_makes_no_charging_changes(self):
        (self.home / "unsupported").touch()
        process = self.start()
        process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.value("fcc"), "2900000")
        self.assertEqual(self.value("enabled"), "1")
        self.assertFalse((self.home / "events").exists())
        self.assertFalse((self.state / "journal").exists())

    def test_stop_interface_waits_for_complete_recovery(self):
        (self.home / "soc").write_text("70")
        process = self.start()
        self.wait_for(lambda: self.status("Holding"))
        result = subprocess.run(
            ["sh", str(ROOT / "runtime.sh"), "stop", str(self.state), str(self.driver), str(self.module)],
            env=self.environment, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        process.communicate(timeout=5)
        self.assertEqual(self.value("fcc"), "2900000")
        self.assertEqual(self.value("enabled"), "1")
        self.assertFalse((self.state / "journal").exists())

    def test_successful_initialization_can_cross_a_lease_cumulatively(self):
        (self.home / "delay").touch()
        process = self.start()
        self.wait_for(lambda: self.status("Charging"))
        self.assertFalse((self.state / "fault").exists())
        self.finish(process)

    def test_enabled_policy_without_suspension_cannot_release_zero_fcc(self):
        (self.home / "soc").write_text("70")
        process = self.start()
        self.wait_for(lambda: self.status("Holding"))
        (self.home / "stuck-input").touch()
        (self.home / "temp").write_text("400")
        process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.value("enabled"), "1")
        self.assertEqual(self.value("fcc"), "0")
        self.assertTrue((self.state / "journal").exists())
        self.assertTrue(self.status("Fault"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
