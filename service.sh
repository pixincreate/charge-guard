#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
set -u
umask 077
MODDIR=${0%/*}
STATE=/data/adb/lavender-battery-guard
[ ! -L "$STATE" ] || exit 1
mkdir -p "$STATE/bin" || exit 1
[ "$(stat -c '%u %g' "$STATE")" = '0 0' ] || exit 1
chmod 700 "$STATE" "$STATE/bin" || exit 1
# Recovery code remains available if Magisk removes the module directory.
for script in runtime.sh device.sh bounded-command.sh recovery-ready.sh display.sh; do
    cp "$MODDIR/$script" "$STATE/bin/$script.next" &&
        chmod 700 "$STATE/bin/$script.next" &&
        mv "$STATE/bin/$script.next" "$STATE/bin/$script" || exit 1
done
publish() {
    /system/bin/timeout --foreground -s TERM -k 1 2 setsid sh "$STATE/bin/bounded-command.sh" \
        sh "$STATE/bin/display.sh" publish "$STATE" "$MODDIR" "$1" || true
}
printf 'Starting\n' > "$STATE/status"
publish Starting
remaining=60
while [ "$remaining" -gt 0 ]; do
    if [ "$(getprop sys.boot_completed)" = 1 ]; then
        exec sh "$STATE/bin/runtime.sh" supervise "$STATE" "$STATE/bin/device.sh" "$MODDIR" >> "$STATE/run.log" 2>&1
    fi
    remaining=$((remaining - 1))
    sleep 2 || exit 1
done
printf 'Android services do not become ready.\n' > "$STATE/fault"
printf 'Fault\n' > "$STATE/status"
publish Fault
