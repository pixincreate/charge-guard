# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class DisplayTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="battery-display-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.state = self.home / "state"
        self.module = self.home / "module"
        self.state.mkdir()
        self.module.mkdir()
        self.metadata = "id=fixture\nname=Battery guard\nversion=1.0.2\nversionCode=3\nauthor=PiX\ndescription=Original\n"
        (self.module / "module.prop").write_text(self.metadata)
        (self.module / "module.prop").chmod(0o640)

    def call(self, *arguments):
        return subprocess.run(["sh", str(ROOT / "display.sh"), *map(str, arguments)],
                              capture_output=True, text=True, timeout=10)

    def test_magisk_relative_action_reports_unavailable_runtime_instead_of_empty_output(self):
        for name in ("action.sh", "display.sh"):
            shutil.copyfile(ROOT / name, self.module / name)
        driver = self.module / "device.sh"
        driver.write_text("#!/bin/sh\nexit 1\n")
        driver.chmod(0o700)
        result = subprocess.run(["sh", "./action.sh"], cwd=self.module,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Health: Not running", result.stdout)
        self.assertIn("Sensors: Unavailable", result.stdout)

    def prepare_report(self):
        self.driver = self.home / "driver"
        self.driver.write_text('''#!/bin/sh
case "$1" in
    clock) cat "${0%/*}/clock" ;;
    boot) echo boot-a ;;
    sensors) cat "${0%/*}/sensors" ;;
    diagnostics)
        [ ! -f "${0%/*}/diagnostics-delay" ] || exec sleep 20
        cat "${0%/*}/diagnostics" ;;
    *) exit 2 ;;
esac
''')
        self.driver.chmod(0o700)
        (self.home / "clock").write_text("200\n")
        (self.home / "sensors").write_text("70 1 1 370\n")
        (self.home / "diagnostics").write_text(
            "current_ua=-39000\nvoltage_uv=3800000\nprofile_fcc_ua=0\nmain_fcc_ua=0\n"
            "battery_health=Good\njeita=1\nselinux=Enforcing\nkernel_match=Verified\n"
            "kernel_release=4.19.325-test\nrom_enabled=0\nrom_service_enabled=0\n"
            "rom_service_active=0\nrom_mode=3\nrom_limit=70\n")
        for name, value in {"boot": "boot-a", "status": "Holding", "guard-heartbeat": "199",
                            "controller-heartbeat": "198", "journal": "private snapshot"}.items():
            (self.state / name).write_text(value + "\n")
        pid = os.getpid()
        if Path(f"/proc/{pid}/stat").exists():
            identity = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()[19]
        else:
            identity = " ".join(subprocess.check_output(
                ["/bin/ps", "-o", "lstart=", "-p", str(pid)], text=True).split())
        (self.state / "guard").write_text(f"{pid} {identity}\n")
        self.controller = subprocess.Popen(["sleep", "60"])
        self.addCleanup(self.controller.wait)
        self.addCleanup(self.controller.terminate)
        (self.state / "controller.pid").write_text(f"{self.controller.pid}\n")

    def test_current_check_reports_healthy_controller_without_writes(self):
        self.prepare_report()
        before = {str(p): (p.read_bytes(), p.stat().st_mode) for p in self.home.rglob("*") if p.is_file()}
        result = self.call("report", self.state, self.module, self.driver)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Health: Working", result.stdout)
        self.assertIn("State: Holding", result.stdout)
        self.assertIn("Battery: 70%", result.stdout)
        self.assertIn("Temperature: 37.0°C", result.stdout)
        self.assertIn("Adapter: Online", result.stdout)
        self.assertEqual({str(p): (p.read_bytes(), p.stat().st_mode)
                          for p in self.home.rglob("*") if p.is_file()}, before)

    def test_expired_or_future_checks_do_not_report_working(self):
        self.prepare_report()
        for value in ("169", "201", "invalid"):
            with self.subTest(heartbeat=value):
                (self.state / "controller-heartbeat").write_text(value + "\n")
                result = self.call("report", self.state, self.module, self.driver)
                self.assertIn("Health: Not running", result.stdout)

    def test_electrical_readings_use_battery_sign_and_distinguish_fcc_values(self):
        self.prepare_report()
        result = self.call("report", self.state, self.module, self.driver)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Battery current: -39.0 mA (discharging)", result.stdout)
        self.assertIn("Battery voltage: 3.800 V", result.stdout)
        self.assertIn("Estimated battery power: -148.2 mW", result.stdout)
        self.assertIn("sequential battery readings", result.stdout)
        self.assertIn("Battery FCC vote: 0 mA", result.stdout)
        self.assertIn("Main FCC parameter: 0 mA", result.stdout)
        self.assertIn("Kernel build: Verified", result.stdout)
        self.assertIn("ROM policy check: Matches active override", result.stdout)

    def test_positive_and_zero_battery_current_are_not_called_discharge(self):
        self.prepare_report()
        data = (self.home / "diagnostics").read_text()
        for value, current, power in (("100000", "100.0 mA (charging)", "380.0 mW"),
                                       ("0", "0.0 mA (zero reported)", "0.0 mW")):
            with self.subTest(current=value):
                (self.home / "diagnostics").write_text(data.replace("-39000", value))
                result = self.call("report", self.state, self.module, self.driver)
                self.assertIn("Battery current: " + current, result.stdout)
                self.assertIn("Estimated battery power: " + power, result.stdout)

    def test_missing_invalid_or_duplicate_readings_are_not_invented(self):
        self.prepare_report()
        data = (self.home / "diagnostics").read_text()
        for changed in (data.replace("voltage_uv=3800000\n", ""),
                        data.replace("voltage_uv=3800000", "voltage_uv=invalid"),
                        data + "voltage_uv=3800000\n"):
            with self.subTest(data=changed):
                (self.home / "diagnostics").write_text(changed)
                result = self.call("report", self.state, self.module, self.driver)
                self.assertIn("Health: Working", result.stdout)
                self.assertIn("Battery voltage: Unavailable", result.stdout)
                self.assertIn("Estimated battery power: Unavailable", result.stdout)

    def test_optional_diagnostic_timeout_does_not_change_required_health(self):
        self.prepare_report()
        (self.home / "diagnostics-delay").touch()
        result = self.call("report", self.state, self.module, self.driver)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Health: Working", result.stdout)
        self.assertIn("Battery: 70%", result.stdout)
        self.assertIn("Battery current: Unavailable", result.stdout)

    def test_policy_summary_reports_conflict_without_changing_control(self):
        self.prepare_report()
        data = (self.home / "diagnostics").read_text().replace("rom_enabled=0", "rom_enabled=1")
        (self.home / "diagnostics").write_text(data)
        result = self.call("report", self.state, self.module, self.driver)
        self.assertIn("ROM policy check: Conflict detected", result.stdout)

    def test_report_explains_state_and_uses_monotonic_state_entry(self):
        self.prepare_report()
        (self.state / "state-entry").write_text("boot-a Holding 180\n")
        (self.state / "display-time").write_text("A card refresh does not change state entry.\n")
        result = self.call("report", self.state, self.module, self.driver)
        self.assertIn("Next threshold: Resume charging at 65%", result.stdout)
        self.assertIn("State duration: 20 s", result.stdout)
        self.assertIn("Guard check age: 1 s", result.stdout)
        self.assertIn("Controller check age: 2 s", result.stdout)

    def test_invalid_old_or_mismatched_state_entry_has_no_duration(self):
        self.prepare_report()
        for entry in ("old-boot Holding 180", "boot-a Charging 180", "boot-a Holding 201",
                      "boot-a Holding invalid", "boot-a Holding 180 extra"):
            with self.subTest(entry=entry):
                (self.state / "state-entry").write_text(entry + "\n")
                result = self.call("report", self.state, self.module, self.driver)
                self.assertIn("State duration: Unavailable", result.stdout)
                self.assertIn("Health: Working", result.stdout)

    def test_check_ages_distinguish_expired_future_and_old_boot_values(self):
        self.prepare_report()
        (self.state / "controller-heartbeat").write_text("169\n")
        result = self.call("report", self.state, self.module, self.driver)
        self.assertIn("Controller check age: 31 s (expired)", result.stdout)
        (self.state / "controller-heartbeat").write_text("201\n")
        result = self.call("report", self.state, self.module, self.driver)
        self.assertIn("Controller check age: Unavailable", result.stdout)
        (self.state / "boot").write_text("old-boot\n")
        result = self.call("report", self.state, self.module, self.driver)
        self.assertIn("Guard check age: Unavailable", result.stdout)

    def test_invalid_optional_fields_do_not_appear_as_valid_readings(self):
        self.prepare_report()
        (self.home / "diagnostics").write_text(
            "current_ua=--39000\nvoltage_uv=0\nprofile_fcc_ua=-1\nmain_fcc_ua=invalid\n"
            "battery_health=Bad\033[31m\njeita=2\nselinux=Other\nkernel_match=Other\n"
            "kernel_release=bad release\nrom_enabled=2\nrom_service_enabled=0\nrom_mode=4\nrom_limit=101\n")
        result = self.call("report", self.state, self.module, self.driver)
        for label in ("Battery current", "Battery voltage", "Estimated battery power", "Battery FCC vote",
                      "Main FCC parameter", "Battery condition", "JEITA enabled", "SELinux", "Kernel build",
                      "Kernel release", "ROM provider enabled", "ROM mode", "ROM limit", "ROM policy check"):
            self.assertIn(label + ": Unavailable", result.stdout)
        self.assertIn("Health: Working", result.stdout)
        self.assertNotIn("\033", result.stdout)

    def test_previous_boot_does_not_report_working(self):
        self.prepare_report()
        (self.state / "boot").write_text("old-boot\n")
        result = self.call("report", self.state, self.module, self.driver)
        self.assertIn("Health: Not running", result.stdout)
        self.assertIn("belongs to another boot", result.stdout)

    def test_wrong_process_identity_does_not_report_working(self):
        self.prepare_report()
        (self.state / "guard").write_text(f"{os.getpid()} wrong-identity\n")
        result = self.call("report", self.state, self.module, self.driver)
        self.assertIn("Health: Not running", result.stdout)

    def test_dead_controller_does_not_report_working_with_fresh_files(self):
        self.prepare_report()
        self.controller.terminate()
        self.controller.wait(timeout=5)
        result = self.call("report", self.state, self.module, self.driver)
        self.assertIn("Health: Not running", result.stdout)

    def test_pending_stop_does_not_report_working(self):
        self.prepare_report()
        (self.state / "stop").touch()
        result = self.call("report", self.state, self.module, self.driver)
        self.assertIn("Health: Stopped", result.stdout)
        self.assertIn("stopped or stopping", result.stdout)

    def test_fault_includes_reason_and_retained_recovery_state(self):
        self.prepare_report()
        (self.state / "fault").write_text("Recovery fails.\n")
        result = self.call("report", self.state, self.module, self.driver)
        self.assertIn("Health: Fault", result.stdout)
        self.assertIn("Fault: Recovery fails.", result.stdout)
        self.assertIn("Recovery journal: Present", result.stdout)

    def test_failed_or_hot_sensor_check_does_not_report_working(self):
        self.prepare_report()
        for value in ("unavailable", "70 1 1 400"):
            with self.subTest(sensors=value):
                (self.home / "sensors").write_text(value + "\n")
                result = self.call("report", self.state, self.module, self.driver)
                self.assertIn("Health: Check failed", result.stdout)

    def test_invalid_description_input_does_not_change_metadata(self):
        before = (self.module / "module.prop").read_bytes()
        result = self.call("publish", self.state, self.module, "Holding\nid=other")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.module / "module.prop").read_bytes(), before)

    def test_ambiguous_metadata_is_not_replaced(self):
        before = self.metadata + "description=Duplicate\n"
        (self.module / "module.prop").write_text(before)
        result = self.call("publish", self.state, self.module, "Holding")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.module / "module.prop").read_text(), before)

    def test_removed_module_is_not_recreated(self):
        (self.module / "module.prop").unlink()
        self.module.rmdir()
        result = self.call("publish", self.state, self.module, "Stopped")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.module.exists())

    def test_publish_changes_only_description_and_keeps_file_metadata(self):
        before = (self.module / "module.prop").stat()
        result = self.call("publish", self.state, self.module, "Holding")
        self.assertEqual(result.returncode, 0, result.stderr)
        props = (self.module / "module.prop").read_text().splitlines()
        self.assertEqual([line for line in props if not line.startswith("description=")],
                         [line for line in self.metadata.splitlines() if not line.startswith("description=")])
        description = next(line for line in props if line.startswith("description="))
        self.assertTrue(description.startswith("description=[Holding] Last reported: "), description)
        self.assertIn("Stop 70%; resume 65%", description)
        self.assertIn((self.state / "display-time").read_text().strip(), description)
        after = (self.module / "module.prop").stat()
        self.assertEqual((after.st_mode, after.st_uid, after.st_gid),
                         (before.st_mode, before.st_uid, before.st_gid))


if __name__ == "__main__":
    unittest.main(verbosity=2)
