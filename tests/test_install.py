# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="charge-guard-install-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.payload = self.home / "payload"
        self.payload.mkdir()
        self.events = self.home / "events"
        (self.payload / "device.sh").write_text(
            '#!/bin/sh\nprintf "compatible\\n" >> "$INSTALL_EVENTS"\n')
        installer = (ROOT / "customize.sh").read_text()
        # Redirect only Magisk's module-directory boundary into private fixtures.
        for directory in ("modules", "modules_update"):
            installer = installer.replace(f"/data/adb/{directory}/lavender_battery_guard",
                                          str(self.home / directory / "lavender_battery_guard"))
        installer = installer.replace("/data/adb/lavender-battery-guard",
                                      str(self.home / "lavender-battery-guard"))
        self.installer = self.home / "customize.sh"
        self.installer.write_text(installer)
        self.wrapper = self.home / "install.sh"
        self.wrapper.write_text('''#!/bin/sh
abort() { printf '%s\n' "$*" >&2; exit 1; }
ui_print() { :; }
set_perm() { printf 'permissions\n' >> "$INSTALL_EVENTS"; }
set_perm_recursive() { printf 'permissions\n' >> "$INSTALL_EVENTS"; }
. "$INSTALL_SCRIPT"
''')
        self.environment = dict(os.environ, BOOTMODE="true", MODPATH=str(self.payload),
                                INSTALL_SCRIPT=str(self.installer), INSTALL_EVENTS=str(self.events))

    def install(self):
        return subprocess.run(["sh", str(self.wrapper)], env=self.environment,
                              capture_output=True, text=True, timeout=5)

    def reject_legacy(self, directory):
        legacy = self.home / directory / "lavender_battery_guard"
        for marker in (None, "disable", "remove"):
            with self.subTest(marker=marker):
                legacy.mkdir(parents=True)
                (legacy / "module.prop").write_text("id=lavender_battery_guard\n")
                if marker:
                    (legacy / marker).touch()
                before = {path.name: path.read_bytes() for path in legacy.iterdir()}
                try:
                    result = self.install()
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("reboot", result.stderr.lower())
                    self.assertFalse(self.events.exists())
                    self.assertEqual({path.name: path.read_bytes() for path in legacy.iterdir()}, before)
                finally:
                    shutil.rmtree(legacy)

    def test_installed_legacy_module_blocks_setup_even_when_disabled_or_removed(self):
        self.reject_legacy("modules")

    def test_pending_legacy_module_blocks_setup_even_when_disabled_or_removed(self):
        self.reject_legacy("modules_update")

    def test_clean_install_preserves_existing_recovery_data(self):
        state = self.home / "lavender-battery-guard"
        state.mkdir()
        journal = state / "journal"
        journal.write_text("pending recovery\n")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("compatible\n", self.events.read_text())
        self.assertIn("permissions\n", self.events.read_text())
        self.assertEqual(journal.read_text(), "pending recovery\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
