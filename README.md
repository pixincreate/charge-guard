# Charge Guard

Historical version 1.0.2, imported from its release ZIP.
Use version 1.0.5 for the latest diagnostics and fixes.
See [CHANGELOG.md](CHANGELOG.md) for import provenance and release changes.

## Compatibility and operation

This Magisk module supports Redmi Note 7/7S (`lavender`), crDroid 13.0 / Android 17, and Magisk 31100.
The required kernel GNU build ID is `68e104c18f8aa96b3f8d008f58a293e3fbe60099`; other builds are rejected.
Enable the ROM charging controller in limit mode with a 70% limit before activation.
Do not use another charging controller or change the ROM policy while this module operates.
It stops charging at 70%, resumes at 65% after holding, and leaves adapter input available while holding.
FCC zero is a current target, not battery isolation or zero battery use.
The internal module ID is `lavender_battery_guard`.

## Install

Build with `uv run --no-project python build.py`.
Install `dist/charge-guard-1.0.2.zip` through Magisk Modules and reboot.
No Magisk core build is required.

## Status

The card shows the last reported state and timestamp.
Magisk caches this text; restart the app to refresh it.
The relative Action invocation has a known issue fixed in version 1.0.4.

## Recovery and limits

On unplug, the module restores stock control and starts a fresh session on replug.
Sensor, runtime, and policy failures or temperature at or above 40°C trigger recovery and stop control until reboot.
Recovery restores ROM policy before normal FCC and requires input suspension at or above the limit while connected.
Failed recovery retains the journal and reports Fault; charging may remain stopped.
Do not delete `/data/adb/lavender-battery-guard` while control operates or recovery data exists.
The ROM-policy override is persistent: after an abrupt reboot with the module disabled or unavailable, restore the ROM controller in Android battery settings.
An enabled module recovers pending policy but never replays a previous boot's FCC into a changed kernel.
No shell guard guarantees recovery from kernel hangs, blocked I/O, simultaneous termination, or lost recovery data.
The module never writes main FCC, input suspension, thermal controls, calibration, or SELinux policy.

This prototype does not establish increased battery lifetime.
Brief phone checks observe holding and fallback, with approximately 39 mA of reported residual discharge.
Resuming at 65%, sustained operation, and unassisted reconnect remain unverified on the phone.
Keep the phone cool and stop using it if the battery swells.
The available host and Android regression tests are included with the latest source snapshot, not reconstructed as historical tests.

## License and attribution

Copyright (C) 2026 PiX (`pixincreate`).
Licensed under GPL-3.0-only; see [LICENSE](LICENSE).
Redistributed copies must retain applicable copyright and license notices and meet GPL source-distribution requirements.
