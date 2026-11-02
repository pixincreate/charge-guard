#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
"""Build a Magisk-app ZIP from an explicit payload list."""

from pathlib import Path
import stat
import zipfile


ROOT = Path(__file__).resolve().parent
PAYLOAD = (
    "module.prop", "customize.sh", "service.sh", "runtime.sh", "device.sh",
    "bounded-command.sh", "recovery-ready.sh", "uninstall.sh", "README.md", "LICENSE",
    "display.sh", "action.sh",
)


def build():
    metadata = dict(line.split("=", 1) for line in (ROOT / "module.prop").read_text().splitlines())
    destination = ROOT / "dist" / f"charge-guard-{metadata['version']}.zip"
    destination.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in PAYLOAD:
            entry = zipfile.ZipInfo(name, date_time=(2026, 11, 2, 0, 0, 0))
            mode = 0o755 if name.endswith(".sh") else 0o644
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, (ROOT / name).read_bytes())
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise ValueError("The ZIP integrity check fails.")
    print(destination)
    return destination


if __name__ == "__main__":
    build()
