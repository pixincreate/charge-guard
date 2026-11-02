# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = "68e104c18f8aa96b3f8d008f58a293e3fbe60099"
BOOT = "11111111-1111-1111-1111-111111111111"


class DeviceRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="charge-guard-device-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        for supply in ("battery", "main", "usb"):
            (self.home / supply).mkdir()
        for name, value in {
            "battery/constant_charge_current_max": "0", "main/constant_charge_current_max": "0",
            "battery/capacity": "60", "battery/input_suspend": "0", "usb/present": "1",
            "enabled": "0", "limit": "70", "controlmode": "3", "start": "absent",
            "target": "absent", "boot": BOOT,
        }.items():
            (self.home / name).write_text(value + "\n")
        self.fcc = self.home / "battery/constant_charge_current_max"
        self.fcc.chmod(0o444)
        self.journal = self.home / "journal"
        self.journal.write_text(
            f"schema=1\nboot={BOOT}\nkernel={BUILD}\nfcc=2900000\nmode=444\n"
            "enabled=1\nlimit=70\ncontrolmode=3\nstart=absent\ntarget=absent\n")
        self.journal.chmod(0o600)
        # Redirect only the sysfs boundary. All adapter logic runs through its real CLI.
        adapter = (ROOT / "device.sh").read_text()
        for variable, supply in (("B", "battery"), ("M", "main"), ("U", "usb")):
            adapter = adapter.replace(f"{variable}=/sys/class/power_supply/{supply}\n",
                                      f'{variable}="$FIXTURE/{supply}"\n')
        (self.home / "device.sh").write_text(adapter)
        (self.home / "recovery-ready.sh").write_bytes((ROOT / "recovery-ready.sh").read_bytes())
        self.ipc = self.home / "android-ipc"
        self.ipc.write_text(f'''#!{sys.executable}
from pathlib import Path
import os, sys, time
p = Path(os.environ['FIXTURE'])
command, *args = sys.argv[1:]
keys = {{'charging_control_enabled': 'enabled', 'charging_control_charging_limit': 'limit',
        'charging_control_mode': 'controlmode', 'charging_control_start_time': 'start',
        'charging_control_target_time': 'target'}}
if command == 'content' and args[0] == 'insert':
    value = next(arg.removeprefix('value:s:') for arg in args if arg.startswith('value:s:'))
    (p / 'enabled').write_text(value + '\\n')
elif command == 'content':
    key = args[args.index('--uri') + 1].rsplit('/', 1)[1]
    if key == 'charging_control_mode' and (p / 'slow-policy').exists(): time.sleep(4)
    value = (p / keys[key]).read_text().strip()
    print('No result found.' if value == 'absent' else 'Row: 0 value=' + value)
elif command == 'dumpsys':
    enabled = 'true' if (p / 'enabled').read_text().strip() == '1' else 'false'
    print('Enabled:', enabled)
    print('mIsEnabled:', enabled)
else:
    sys.exit(2)
''')
        self.ipc.chmod(0o700)
        self.wrapper = self.home / "adapter.sh"
        self.wrapper.write_text('''#!/bin/sh
id() { printf '0\n'; }
getprop() { printf 'lavender\n'; }
stat() {
    case "$2" in
        '%a %u %g') printf '600 0 0\n' ;;
        '%u %g') printf '0 0\n' ;;
        %a) printf '444\n' ;;
        *) return 2 ;;
    esac
}
od() { printf '040000001400000003000000474e5500%s\n' "$FIXTURE_BUILD"; }
cat() {
    if [ "$1" = /proc/sys/kernel/random/boot_id ]; then
        command cat "$FIXTURE/boot"
    else
        command cat "$@"
    fi
}
timeout() (
    signal_option=$1 signal_name=$2 seconds=$3
    shift 3
    android_command=${1##*/}
    shift
    command timeout "$signal_option" "$signal_name" "$seconds" "$FIXTURE/android-ipc" "$android_command" "$@"
)
. "$FIXTURE/device.sh"
''')
        self.environment = dict(os.environ, FIXTURE=str(self.home), FIXTURE_BUILD=BUILD)

    def recover(self):
        return subprocess.run(["sh", str(self.wrapper), "recover", str(self.journal)],
                              env=self.environment, capture_output=True, text=True, timeout=10)

    def value(self, path):
        return (self.home / path).read_text().strip()

    def test_matching_policy_restores_original_current(self):
        result = self.recover()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.value("enabled"), "1")
        self.assertEqual(self.value("battery/constant_charge_current_max"), "2900000")
        self.assertEqual(self.fcc.stat().st_mode & 0o777, 0o444)

    def test_policy_conflicts_keep_zero_current_and_restore_rom_enable(self):
        for key, conflicting in (("limit", "100"), ("controlmode", "2"),
                                 ("start", "79200"), ("target", "21600")):
            with self.subTest(key=key):
                original = (self.home / key).read_text()
                (self.home / key).write_text(conflicting)
                result = self.recover()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.value("enabled"), "1")
                self.assertEqual(self.value("battery/constant_charge_current_max"), "0")
                self.assertEqual(self.fcc.stat().st_mode & 0o777, 0o444)
                (self.home / key).write_text(original)

    def test_matching_policy_after_reboot_does_not_replay_old_current(self):
        (self.home / "boot").write_text("22222222-2222-2222-2222-222222222222")
        self.fcc.chmod(0o644)
        self.fcc.write_text("1800000")
        self.fcc.chmod(0o444)
        result = self.recover()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.value("enabled"), "1")
        self.assertEqual(self.value("battery/constant_charge_current_max"), "1800000")

    def test_policy_conflict_after_reboot_fails_without_replaying_old_current(self):
        (self.home / "boot").write_text("22222222-2222-2222-2222-222222222222")
        (self.home / "limit").write_text("100")
        result = self.recover()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.value("enabled"), "1")
        self.assertEqual(self.value("battery/constant_charge_current_max"), "0")

    def test_stalled_policy_read_fails_without_releasing_zero_current(self):
        (self.home / "slow-policy").touch()
        result = self.recover()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.value("enabled"), "1")
        self.assertEqual(self.value("battery/constant_charge_current_max"), "0")


if __name__ == "__main__":
    unittest.main(verbosity=2)
