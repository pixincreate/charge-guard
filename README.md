# Charge Guard

A device-specific Magisk module that stops charging at 70% and resumes at 65%.
While holding, it requests a zero battery-profile fast-charge-current (FCC) target and keeps adapter input available.
The battery remains connected and can still supply current.
This is not battery isolation or a guarantee against battery aging.

## Compatibility

- Redmi Note 7/7S (`lavender`).
- crDroid 13.0 / Android 17, tested with Magisk 31100.
- Kernel GNU build ID: `68e104c18f8aa96b3f8d008f58a293e3fbe60099`.
- ROM charging control enabled in limit mode with a 70% limit before activation.

Other kernel builds are rejected, even if their version strings match.
Do not use another charging-control module or change the ROM charging configuration while Charge Guard operates.
The internal module ID remains `lavender_battery_guard` for update compatibility.

## Install

1. Build `dist/charge-guard-1.0.5.zip`, or obtain that ZIP from the project owner.
2. In Magisk, select **Modules → Install from storage** and select the ZIP.
3. Reboot.

Charge Guard activates after Android boot completion.
It charges below 70%, holds at 70%, and resumes at or below 65% after holding.
It restores stock charging control on unplug and starts a fresh session on replug.
Sensor failures, policy conflicts, runtime failures, or temperature at or above 40°C trigger recovery and stop control until reboot.
The module does not write main FCC, input suspension, thermal controls, calibration, or SELinux policy.

## Status

The Magisk card shows `[Starting]`, `[Charging]`, `[Holding]`, `[Released]`, `[Stopped]`, or `[Fault]`, with the last report time.
The description updates on state changes and approximately once per minute.
Magisk caches this text: on the tested app, switching tabs does not refresh it, but restarting the app does.
Cached text is not proof that control still operates.

Select **Action** for a read-only check of process identities, current-boot heartbeats, sensors, state duration, next threshold, and faults.
It also shows battery current, voltage, estimated battery power, FCC targets, and reported safety and ROM-policy states.
`Health: Working` requires both processes, completed checks less than 30 seconds old, and a successful current sensor check.
Action does not restart control or change charging settings.

Negative current means reported battery discharge.
Estimated power comes from sequential battery readings, not adapter consumption.
FCC values are current targets, not net battery current.
Optional fields show `Unavailable` when missing or invalid; they do not determine controller health.
The Action policy summary checks enabled state, mode, and limit; the controller separately checks the full policy, including schedules.

## Recovery and updates

Recovery restores the ROM controller before restoring the captured battery FCC vote and file permissions.
At or above 70% with power connected, it first verifies that the ROM suspends input.
Failed recovery retains the journal and reports `Fault`; charging may remain stopped.
An independent guard waits for the inherited writer lock before recovery so surviving operations cannot write afterward.

Read diagnostics as root:

```sh
adb shell "su -c 'cat /data/adb/lavender-battery-guard/status'"
adb shell "su -c 'cat /data/adb/lavender-battery-guard/fault'"
adb shell "su -c 'cat /data/adb/lavender-battery-guard/run.log'"
```

Do not delete `/data/adb/lavender-battery-guard` while control operates or a recovery journal exists.
The ROM-policy override is persistent: after an abrupt reboot with the module disabled or unavailable, the ROM charging controller can remain disabled.
Restore it in Android battery settings in that case; its stored limit remains 70%.
An enabled module resolves pending recovery before acquiring control and never replays a previous boot's FCC value into a changed kernel.
Kernel or ROM updates require interface revalidation; do not remove the build-ID restriction to bypass this check.
No shell guard guarantees recovery from a kernel hang, blocked kernel I/O, simultaneous process termination, or lost recovery data.

## Validation limits

Phone checks observe holding at 70%, zero FCC targets with adapter input online, restoration, and brief battery fallback without a reboot.
The gauge reports residual battery discharge of approximately 39 mA during the adapter-active experiment.
Resuming at 65%, sustained operation, and unassisted reconnect remain unverified on the phone.
This is a prototype, not evidence of increased battery lifetime.
Keep the phone cool and stop using it if the battery swells.

## Build and test

Use Python 3, `uv`, ShellCheck, and a POSIX host with `timeout` on `PATH`.
Packaging uses the Python standard library; no Magisk core build is required.

```sh
uv run --no-project python -m unittest discover -s tests
shellcheck ./*.sh tests/*.sh
for script in ./*.sh tests/*.sh; do sh -n "$script" || exit; done
uv run --no-project python build.py
```

Host tests run the actual runtime with file-backed controls and native lock/session command adapters.
They do not operate the phone's charging driver.
For Android runtime checks, stage `runtime.sh`, `bounded-command.sh`, `display.sh`, and `tests/test_android_runtime.sh` in a private directory and run the test as root with that directory as its argument.
For adapter checks, stage `device.sh`, `display.sh`, and `tests/test_android_diagnostics.sh` together and run that test the same way.
These tests use private fixtures; they do not change real charging controls.

## License and attribution

Copyright (C) 2026 PiX (`pixincreate`).
Licensed under **GPL-3.0-only**; see [LICENSE](LICENSE).
Redistributed copies must retain applicable copyright and license notices.
Distributed derivatives must meet the GPL source-distribution requirements.
See [CHANGELOG.md](CHANGELOG.md) for the imported release history.
