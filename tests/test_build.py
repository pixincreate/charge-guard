# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]


class BuildTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="charge-guard-build-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        for source in ROOT.iterdir():
            if source.is_file():
                shutil.copy2(source, self.home / source.name)

    def build(self):
        return subprocess.run([sys.executable, str(self.home / "build.py")],
                              capture_output=True, text=True, timeout=10)

    def test_build_preserves_payload_and_produces_identical_archives(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = next((self.home / "dist").glob("*.zip"))
        first = archive.read_bytes()
        sources = list(self.home.glob("*.sh")) + [self.home / name for name in ("module.prop", "README.md", "LICENSE")]
        with zipfile.ZipFile(archive) as package:
            self.assertIsNone(package.testzip())
            self.assertEqual({name: package.read(name) for name in package.namelist()},
                             {source.name: source.read_bytes() for source in sources})
            for entry in package.infolist():
                self.assertEqual((entry.external_attr >> 16) & 0o777,
                                 0o755 if entry.filename.endswith(".sh") else 0o644)
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(archive.read_bytes(), first)

    def test_missing_action_files_fail_the_build(self):
        for name in ("action.sh", "display.sh"):
            with self.subTest(name=name):
                source = self.home / name
                saved = source.read_bytes()
                source.unlink()
                try:
                    result = self.build()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stderr)
                finally:
                    source.write_bytes(saved)


if __name__ == "__main__":
    unittest.main(verbosity=2)
