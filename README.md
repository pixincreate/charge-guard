# Charge Guard

A Magisk module for phones that stay plugged in.
It stops charging at **70%** and resumes at **65%**.

For Redmi Note 7/7S running crDroid 13 / Android 17.
Tested with Magisk 31100.
Only the tested kernel build is accepted; other builds are blocked.

## Install

1. Enable Android's charging limit and set it to 70%.
2. Download `charge-guard-1.0.6.zip` from [Releases](https://github.com/pixincreate/charge-guard/releases/latest), under **Assets**.
3. Select the ZIP in **Magisk → Modules → Install from storage**.
4. Reboot and tap **Action** to check that it works.

Do not install GitHub's **Source code** ZIP.

## Status

**Action** shows whether the module is running, battery readings, and any fault.
It does not change settings.
Close and reopen it for a fresh check.

The module card can show old status.
Restart Magisk to refresh it; switching tabs does not work.

## Important

- The battery stays connected. Some battery drain remains; our test reports about 39 mA while holding.
- At 40°C or after a failed check, the module tries to restore Android's charging control and stops until reboot. Check Action if it reports `Fault`; failed recovery can leave charging stopped.
- Do not use another charging module or change Android's charging settings while this module runs.
- If the module is disabled or missing after an unexpected reboot, Android's charging control can stay off. Turn it back on in battery settings.
- Do not delete `/data/adb/lavender-battery-guard`. It stores recovery data.

Uninstall through Magisk, then reboot.
This is a prototype: resuming at 65% and long-term operation remain unverified on the phone.
It cannot prevent all battery aging.
Keep the phone cool and stop using it if the battery swells.

## Build and test

Use Python 3, `uv`, ShellCheck, and a POSIX host with `timeout` installed.

```sh
uv run --no-project python -m unittest discover -s tests
shellcheck ./*.sh tests/*.sh
for script in ./*.sh tests/*.sh; do sh -n "$script" || exit; done
uv run --no-project python build.py
```

The ZIP is saved in `dist/`.

## License

Copyright (C) 2026 PiX (`pixincreate`).
[GPL-3.0-only](LICENSE).
