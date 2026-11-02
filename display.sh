#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
# Status reporting never changes charging controls.
set -u
umask 077
[ "$#" -eq 4 ] || exit 2
operation=$1
state=$2
module=$3
case "$state:$module" in /*:/*) ;; *) exit 2 ;; esac
number() {
    case "$1" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; esac
    [ "${#1}" -le 10 ]
}
identity() {
    if [ -r "/proc/$1/stat" ]; then
        sed 's/^.*) //' "/proc/$1/stat" | awk '{print $20}'
    else
        /bin/ps -o lstart= -p "$1" | awk '{$1=$1; print}'
    fi
}
responding() {
    read -r guard_pid guard_identity < "$state/guard" || return 1
    read -r controller_pid < "$state/controller.pid" || return 1
    read -r guard_time < "$state/guard-heartbeat" || return 1
    read -r controller_time < "$state/controller-heartbeat" || return 1
    number "$guard_pid" && number "$controller_pid" && number "$guard_time" && number "$controller_time" || return 1
    [ "$guard_pid" -gt 1 ] && [ "$controller_pid" -gt 1 ] &&
        [ "$now" -ge "$guard_time" ] && [ "$((now - guard_time))" -lt 30 ] &&
        [ "$now" -ge "$controller_time" ] && [ "$((now - controller_time))" -lt 30 ] &&
        kill -0 "$guard_pid" 2>/dev/null && kill -0 "$controller_pid" 2>/dev/null &&
        [ "$(identity "$guard_pid")" = "$guard_identity" ] || return 1
    if [ -r "/proc/$controller_pid/stat" ]; then
        parent=$(sed 's/^.*) //' "/proc/$controller_pid/stat" | awk '{print $2}')
    else
        parent=$(/bin/ps -o ppid= -p "$controller_pid" | awk '{print $1}')
    fi
    [ "$parent" = "$guard_pid" ]
}
case "$operation" in
    publish)
        phase=$4
        case "$phase" in Starting|Charging|Holding|Released|Stopped|Fault) ;; *) exit 2 ;; esac
        [ -f "$module/module.prop" ] && [ ! -L "$module/module.prop" ] || exit 1
        checked=$(date -u '+%Y-%m-%d %H:%M:%S UTC') || exit 1
        description="[$phase] Last reported: $checked | Stop 70%; resume 65% | Action: current check."
        temporary=$(mktemp "$module/.module.prop.XXXXXX") || exit 1
        trap 'rm -f "$temporary"' EXIT
        cp -p "$module/module.prop" "$temporary" || exit 1
        awk -v description="$description" '
            /^description=/ {print "description=" description; count++; next}
            {print}
            END {if (count != 1) exit 1}
        ' "$module/module.prop" > "$temporary" || exit 1
        mv "$temporary" "$module/module.prop" || exit 1
        printf '%s\n' "$checked" > "$state/display-time.next" &&
            mv "$state/display-time.next" "$state/display-time" ;;
    report)
        driver=$4
        phase=$(cat "$state/status" 2>/dev/null) || phase=Starting
        checked=$(cat "$state/display-time" 2>/dev/null) || checked='Not reported'
        health='Not running'
        detail='No current controller check is available.'
        boot=$(timeout -s KILL 2 "$driver" boot) || boot=unavailable
        recorded_boot=$(cat "$state/boot" 2>/dev/null) || recorded_boot=absent
        if [ "$boot" != unavailable ] && [ "$boot" = "$recorded_boot" ]; then
            if [ -f "$state/fault" ] || [ "$phase" = Fault ]; then
                health=Fault
                detail='Control has stopped. Inspect the fault and recovery journal.'
            elif [ "$phase" = Stopped ] || [ -e "$state/stop" ] || [ -e "$module/disable" ] || [ -e "$module/remove" ]; then
                health=Stopped
                detail='Automatic charging control is stopped or stopping.'
            else
                now=$(timeout -s KILL 2 "$driver" clock) || now=invalid
                case "$phase" in
                    Charging|Holding|Released)
                        if number "$now" && responding 2>/dev/null; then
                            health=Working
                            detail='Both processes are present; completed checks are less than 30 seconds old.'
                        fi ;;
                esac
            fi
        else
            detail='The stored state is missing or belongs to another boot.'
        fi
        sensor_phase=Released
        [ "$health" != Working ] || sensor_phase=$phase
        sample=$(timeout -s KILL 4 "$driver" sensors "$sensor_phase" "$state/journal") || sample=invalid
        read -r soc present online temperature extra <<EOF
$sample
EOF
        sensors=0
        if number "$soc" && number "$present" && number "$online" && number "$temperature" &&
            [ -z "$extra" ] && [ "$soc" -le 100 ] && [ "$present" -le 1 ] && [ "$online" -le 1 ] &&
            [ "$temperature" -gt 0 ]; then sensors=1; fi
        if [ "$health" = Working ] && { [ "$sensors" = 0 ] || [ "$temperature" -ge 400 ]; }; then
            health='Check failed'
            detail='The current sensor or charging-state check fails.'
        fi
        printf 'Health: %s\nState: %s\n%s\nLast card update: %s\n' "$health" "$phase" "$detail" "$checked"
        if [ "$sensors" = 1 ]; then
            printf 'Battery: %s%%\n' "$soc"
            awk -v temperature="$temperature" 'BEGIN {printf "Temperature: %.1f°C\n", temperature / 10}'
            if [ "$present" = 0 ]; then adapter=Disconnected
            elif [ "$online" = 1 ]; then adapter=Online
            else adapter='Connected, input offline'; fi
            printf 'Adapter: %s\n' "$adapter"
        else
            printf 'Sensors: Unavailable\n'
        fi
        if [ -f "$state/journal" ]; then printf 'Recovery journal: Present\n'; else printf 'Recovery journal: Absent\n'; fi
        if [ -f "$state/fault" ]; then printf 'Fault: '; cat "$state/fault"; fi ;;
    *) exit 2 ;;
esac
