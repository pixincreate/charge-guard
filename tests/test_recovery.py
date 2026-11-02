# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
from pathlib import Path
import subprocess
import unittest


PREDICATE = Path(__file__).resolve().parents[1] / "recovery-ready.sh"


class RecoveryTest(unittest.TestCase):
    def check(self, soc, present, suspended, limit):
        return subprocess.run(
            ["sh", str(PREDICATE), str(soc), str(present), str(suspended), str(limit)],
            capture_output=True, text=True,
        ).returncode

    def test_at_limit_requires_suspension(self):
        self.assertEqual(self.check(70, 1, 0, 70), 1)
        self.assertEqual(self.check(70, 1, 1, 70), 0)

    def test_above_limit_requires_suspension(self):
        self.assertEqual(self.check(80, 1, 0, 70), 1)
        self.assertEqual(self.check(80, 1, 1, 70), 0)

    def test_below_limit_can_restore_current(self):
        self.assertEqual(self.check(69, 1, 0, 70), 0)

    def test_unplug_does_not_require_suspension(self):
        self.assertEqual(self.check(70, 0, 0, 70), 0)

    def test_invalid_sensor_values_cannot_authorize_recovery(self):
        for values in [("missing", 1, 1, 70), (101, 1, 1, 70), (70, 2, 1, 70), (70, 1, 2, 70), (70, 1, 1, 0)]:
            with self.subTest(values=values):
                self.assertEqual(self.check(*values), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
