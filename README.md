# Charge Guard

**Magisk charge control and diagnostics for Redmi Note 7/7S: stop at 70%, resume at 65%.**

Charge Guard controls charging on a verified device and kernel combination.
It provides a read-only Action report and recovery checks for a phone that stays connected to power.
It is not a general-purpose charging module or a guarantee against battery aging.

| Setting | Value |
| --- | --- |
| Module name | Charge Guard |
| Module ID | `charge_guard` |
| Version | `1.0.6` |
| Stop charging | 70% |
| Resume after holding | 65% or below |
| Temperature stop | 40°C or above |
| License | [GPL-3.0-only](LICENSE) |

## What it does

- Charges below 70%, then holds until the battery reaches 65% or below.
- Requests a zero battery-profile fast-charge-current (FCC) target while holding and keeps adapter input available.
- Restores stock charging control on unplug and starts a fresh session on replug.
- Reports controller health, battery readings, and safety checks through Magisk's **Action** button.
- Attempts recovery on sensor failures, policy conflicts, runtime failures, or excessive temperature, then stops control until reboot.

The battery remains connected and can still supply current while holding.
Zero FCC is a charging-current target, not battery isolation or proof of zero battery use.

## Compatibility

- Redmi Note 7/7S (`lavender`).
- crDroid 13.0 / Android 17 (SDK 37), tested with Magisk 31100.
- Kernel GNU build ID: `68e104c18f8aa96b3f8d008f58a293e3fbe60099`.
- ROM charging control enabled in limit mode with a 70% limit before activation.

Other kernel builds are rejected, even if their version strings match.
Do not use another charging-control module or change the ROM charging configuration while Charge Guard operates.

## Migrate from the earlier module ID

Versions 1.0.1–1.0.5 use the ID `lavender_battery_guard`.
The new ID is a separate module in Magisk, not an in-place update.

1. Remove the old module in Magisk, then reboot.
2. Confirm that the old module is absent and ROM charging control is enabled in limit mode at 70%.
3. If recovery fails or its result is unclear, inspect the fault and journal before proceeding.
4. Install the renamed module as described below, then reboot again.

Disabling the old module is not sufficient.
The installer rejects an old-ID directory in either `/data/adb/modules` or `/data/adb/modules_update`, including disabled or removal-marked copies.
Do not install the old ZIP again while the new module is installed.
The persistent recovery path remains `/data/adb/lavender-battery-guard`; do not rename or delete it during migration.

## Install

1. Complete the migration above if an older-ID module is installed.
2. Build `dist/charge-guard-1.0.6.zip` using the instructions below, or obtain that ZIP from the project owner.
3. In Magisk, select **Modules → Install from storage** and select the ZIP.
4. Reboot, then select the module's **Action** button to check operation.

Charge Guard activates after Android boot completion.
The module does not write main FCC, input suspension, thermal controls, calibration, or SELinux policy.

## Status

The Magisk card shows a bracketed state and the last report time.

| State | Meaning |
| --- | --- |
| `[Starting]` | Waiting for boot completion or startup checks. |
| `[Charging]` | Normal charging-current target requested; stop threshold is 70%. |
| `[Holding]` | Zero charging-current target requested; resume threshold is 65%. |
| `[Released]` | Stock charging control restored after unplugging. |
| `[Stopped]` | Automatic control stopped or stopping. |
| `[Fault]` | Control stopped after a failure; inspect Action and the recovery journal. |

The description updates on state changes and approximately once per minute.
Magisk caches this text: on the tested app, switching tabs does not refresh it, but restarting the app does.
Cached text is not proof that control still operates.

### Action report

Select **Action** for a read-only report:

- **Controller:** process identities, current-boot check ages, state explanation, duration, next threshold, and faults.
- **Battery:** charge level, temperature, current, voltage, and estimated battery power.
- **Controls:** battery-profile FCC target, main FCC parameter, adapter availability, and recovery-journal presence.
- **Safety:** reported battery condition, JEITA thermal protection, SELinux, kernel compatibility, and ROM charging-policy status.

`Health: Working` requires both processes, completed checks less than 30 seconds old, and a successful current sensor check.
Action does not restart control or change charging settings.
Close and reopen Action for another check; it is not a continuously updating monitor.

Negative current means reported battery discharge.
Estimated power comes from sequential battery readings, not adapter consumption.
FCC values are current targets, not net battery current.
Optional fields show `Unavailable` when missing or invalid; they do not determine controller health.
The Action policy summary checks enabled state, mode, and limit; the controller separately checks the full policy, including schedules.

## Recovery and updates

Recovery restores the ROM controller and verifies the captured limit, mode, schedule, and enabled state before restoring the captured battery FCC vote and file permissions.
At or above 70% with power connected, it first verifies that the ROM suspends input.
Failed recovery retains the journal and reports `Fault`; charging may remain stopped.
Startup recovery failures remain fault-latched during the same boot, even if a later recovery attempt succeeds.
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
Remove the module through Magisk and reboot to uninstall it.
Do not manually delete recovery data to clear a fault.

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
