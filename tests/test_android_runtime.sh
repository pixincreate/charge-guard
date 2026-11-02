#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
# Run against private file-backed controls, never the charging driver.
set -eu
root=$1
busybox=/data/adb/magisk/busybox
export ASH_STANDALONE=1
home=$("$busybox" mktemp -d /data/local/tmp/lavender-runtime-test.XXXXXX)
export FIXTURE="$home"
guard=
cleanup() {
    touch "$home/state/stop"
    if [ -n "$guard" ]; then wait "$guard" 2>/dev/null || true; fi
    rm -rf "$home"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir "$home/state" "$home/module"
cat > "$home/driver" <<'DRIVER'
#!/system/bin/sh
set -eu
case "$1" in
    clock) read -r up rest < /proc/uptime; printf '%s\n' "${up%%.*}" ;;
    boot) echo fixture-boot ;;
    compatible|policy) exit 0 ;;
    sensors) echo "$(cat "$FIXTURE/soc") 1 1 330" ;;
    diagnostics)
        printf 'current_ua=-39000\nvoltage_uv=3800000\nprofile_fcc_ua=2900000\nmain_fcc_ua=2900000\n'
        printf 'battery_health=Good\njeita=1\nselinux=Enforcing\nkernel_match=Verified\n'
        printf 'kernel_release=4.19-test\nrom_enabled=0\nrom_service_enabled=0\nrom_service_active=0\nrom_mode=3\nrom_limit=70\n' ;;
    snapshot)
        sleep 1
        [ ! -f "$FIXTURE/fail-snapshot" ] || exit 7
        cp "$FIXTURE/fcc" "$2" ;;
    acquire) echo 0 > "$FIXTURE/fcc"; echo 0 > "$FIXTURE/enabled" ;;
    charge) echo 2900000 > "$FIXTURE/fcc" ;;
    hold)
        echo ready > "$FIXTURE/child-ready"
        sleep "$(cat "$FIXTURE/delay")"
        echo 0 > "$FIXTURE/fcc"
        echo delayed-write >> "$FIXTURE/events" ;;
    recover)
        cp "$2" "$FIXTURE/fcc"
        echo 1 > "$FIXTURE/enabled"
        echo recover >> "$FIXTURE/events" ;;
    *) exit 2 ;;
esac
DRIVER
chmod 700 "$home/driver"
wait_for() {
    count=0
    while [ "$count" -lt 100 ]; do
        if [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; then return 0; fi
        sleep 0.1
        count=$((count + 1))
    done
    cat "$home/log" >&2
    return 1
}
run_shell() {
    if [ "$interpreter" = system ]; then
        /system/bin/sh "$@"
    else
        "$busybox" sh "$@"
    fi
}
card_reports() {
    count=0
    while [ "$count" -lt 100 ]; do
        if grep -Fq "description=[$1] Last reported:" "$home/module/module.prop"; then return 0; fi
        sleep 0.1
        count=$((count + 1))
    done
    cat "$home/log" >&2
    return 1
}
for interpreter in system busybox; do
    for scenario in stop child-death snapshot-failure timeout; do
        rm -f "$home/state/stop" "$home/state/fault" "$home/state/status" "$home/child-ready" "$home/fail-snapshot"
        : > "$home/events"
        printf 'id=fixture\nversion=1\ndescription=Original\n' > "$home/module/module.prop"
        echo 69 > "$home/soc"
        echo 2900000 > "$home/fcc"
        echo 1 > "$home/enabled"
        echo 3 > "$home/delay"
        [ "$scenario" != timeout ] || echo 23 > "$home/delay"
        [ "$scenario" != snapshot-failure ] || touch "$home/fail-snapshot"
        run_shell "$root/runtime.sh" supervise "$home/state" "$home/driver" "$home/module" 1 10 > "$home/log" 2>&1 &
        guard=$!
        if [ "$scenario" = snapshot-failure ]; then
            wait_for "$home/state/status" Fault
            if wait "$guard"; then echo 'A failed snapshot reports success.' >&2; exit 1; fi
        else
            wait_for "$home/state/status" Charging
            card_reports Charging
            run_shell "$root/display.sh" report "$home/state" "$home/module" "$home/driver" > "$home/report"
            grep -q '^Health: Working$' "$home/report"
            grep -q '^State: Charging$' "$home/report"
            grep -q '^State duration: [0-9][0-9]* s$' "$home/report"
            grep -q '^Battery current: -39.0 mA (discharging)$' "$home/report"
            grep -q '^Estimated battery power: -148.2 mW' "$home/report"
            grep -q '^ROM policy check: Matches active override' "$home/report"
            [ "$(cat "$home/enabled")" = 0 ]
            run_shell "$root/runtime.sh" supervise "$home/state" "$home/driver" "$home/module" 1 10
        fi
        if [ "$scenario" = stop ]; then
            run_shell "$root/runtime.sh" stop "$home/state" "$home/driver" "$home/module" 1 10
            wait "$guard"
            wait_for "$home/state/status" Stopped
        elif [ "$scenario" = child-death ] || [ "$scenario" = timeout ]; then
            echo 70 > "$home/soc"
            wait_for "$home/child-ready" ready
            [ "$scenario" != child-death ] || kill -KILL "$(cat "$home/state/controller.pid")"
            if wait "$guard"; then echo 'A failed controller reports success.' >&2; exit 1; fi
            if [ "$scenario" = child-death ]; then
                [ "$(cat "$home/events")" = "$(printf 'delayed-write\nrecover')" ]
            else
                [ "$(cat "$home/events")" = recover ]
            fi
            wait_for "$home/state/status" Fault
        fi
        guard=
        [ "$(cat "$home/fcc")" = 2900000 ]
        [ "$(cat "$home/enabled")" = 1 ]
        [ ! -f "$home/state/journal" ]
        if [ "$scenario" = stop ]; then card_reports Stopped; else card_reports Fault; fi
        if [ "$scenario" = timeout ]; then sleep 4; else sleep 1; fi
        [ "$(cat "$home/fcc")" = 2900000 ]
        printf 'PASS: %s %s restores private controls\n' "$interpreter" "$scenario"
    done
done
