#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
# Exercise the actual read-only adapter with controlled sensor inputs on lavender.
set -eu
root=$1
busybox=/data/adb/magisk/busybox
home=$("$busybox" mktemp -d /data/local/tmp/lavender-diagnostics-test.XXXXXX)
trap 'rm -f "$home/report" "$home/formatted" "$home/report-driver"; rmdir "$home/state" "$home/module" "$home"' EXIT
mkdir "$home/state" "$home/module"
export DIAGNOSTIC_ROOT="$root"
cat > "$home/report-driver" <<'DRIVER'
#!/system/bin/sh
case "$1" in
    diagnostics) cat "${0%/*}/report" ;;
    *) exec "$DIAGNOSTIC_ROOT/device.sh" "$@" ;;
esac
DRIVER
chmod 700 "$home/report-driver"
run_shell() {
    if [ "$interpreter" = system ]; then /system/bin/sh "$@"; else "$busybox" sh "$@"; fi
}
diagnose() {
        run_shell -s -- "$root" "$1" "${2:-}" > "$home/report" <<'PROBE'
            root=$1
            fixture_current=$2
            fixture_service=$3
            cat() {
                case "$1" in
                    /sys/class/power_supply/battery/current_now)
                        [ "$fixture_current" != MISSING ] || return 1
                        printf "%s\n" "$fixture_current" ;;
                    /sys/class/power_supply/battery/voltage_now) printf "3800000\n" ;;
                    *) command cat "$@" ;;
                esac
            }
            timeout() {
                if [ -n "$fixture_service" ] && [ "${4:-}" = /system/bin/dumpsys ]; then
                    printf 'Enabled: false\nmIsEnabled: false\nMode: %s\nLimit: %s\n' "$fixture_service" "$fixture_service"
                else command timeout "$@"; fi
            }
            set -- diagnostics
            . "$root/device.sh"
PROBE
}
for interpreter in system busybox; do
    for current in -39000 0 100000 invalid MISSING; do
        diagnose "$current"
        expected=$current
        case "$current" in invalid|MISSING) expected=Unavailable ;; esac
        grep -Fxq "current_ua=$expected" "$home/report"
        grep -Fxq 'voltage_uv=3800000' "$home/report"
        printf 'PASS: %s diagnostics translates current %s without charging writes\n' "$interpreter" "$current"
    done
    for invalid_service in true false invalid; do
        diagnose -39000 "$invalid_service"
        run_shell "$root/display.sh" report "$home/state" "$home/module" "$home/report-driver" > "$home/formatted"
        if ! grep -Fxq 'ROM mode: Unavailable' "$home/formatted" || ! grep -Fxq 'ROM limit: Unavailable' "$home/formatted"; then
            cat "$home/formatted"
            printf 'FAIL: malformed service mode and limit %s must remain unavailable\n' "$invalid_service" >&2
            exit 1
        fi
        printf 'PASS: %s producer-to-report rejects service mode and limit %s\n' "$interpreter" "$invalid_service"
    done
done
