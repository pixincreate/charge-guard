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
check_age() {
    report_age=Unavailable
    if [ "$boot" != unavailable ] && [ "$boot" = "$recorded_boot" ] && number "$now" &&
        [ -f "$state/$2" ] && read -r report_time report_extra < "$state/$2" &&
        [ -z "$report_extra" ] && number "$report_time" && [ "$now" -ge "$report_time" ]; then
        report_age="$((now - report_time)) s"
        [ "$((now - report_time))" -lt 30 ] || report_age="$report_age (expired)"
    fi
    printf '%s: %s\n' "$1" "$report_age"
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
        now=$(timeout -s KILL 2 "$driver" clock) || now=invalid
        if [ "$boot" != unavailable ] && [ "$boot" = "$recorded_boot" ]; then
            if [ -f "$state/fault" ] || [ "$phase" = Fault ]; then
                health=Fault
                detail='Control has stopped. Inspect the fault and recovery journal.'
            elif [ "$phase" = Stopped ] || [ -e "$state/stop" ] || [ -e "$module/disable" ] || [ -e "$module/remove" ]; then
                health=Stopped
                detail='Automatic charging control is stopped or stopping.'
            else
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
        case "$phase" in
            Charging) reason='The normal charge-current target is requested.'; threshold='Stop charging at 70%' ;;
            Holding) reason='The charge-current target is zero; the battery remains connected.'; threshold='Resume charging at 65%' ;;
            Released) reason='Stock charging control is restored.'; threshold='Wait for adapter connection' ;;
            Starting) reason='Startup checks have not completed.'; threshold='Unavailable until startup completes' ;;
            Stopped) reason='Automatic charging control is stopped or stopping.'; threshold='Inactive' ;;
            Fault) reason='Automatic control has stopped after a failure.'; threshold='Inactive; inspect the fault' ;;
            *) reason='The reported state is unknown.'; threshold=Unavailable ;;
        esac
        if [ "$health" != Working ]; then reason="Last reported state: $reason"; fi
        printf 'State reason: %s\nNext threshold: %s\n' "$reason" "$threshold"
        duration=Unavailable
        if [ "$boot" != unavailable ] && [ "$boot" = "$recorded_boot" ] && number "$now" &&
            [ -f "$state/state-entry" ] && read -r entry_boot entry_phase entry_time entry_extra < "$state/state-entry" &&
            [ -z "$entry_extra" ] && [ "$entry_boot" = "$boot" ] && [ "$entry_phase" = "$phase" ] &&
            number "$entry_time" && [ "$now" -ge "$entry_time" ]; then duration="$((now - entry_time)) s"; fi
        printf 'State duration: %s\n' "$duration"
        check_age 'Guard check age' guard-heartbeat
        check_age 'Controller check age' controller-heartbeat
        printf '\n[Battery and controls]\n'
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
        if [ -f "$state/fault" ]; then printf 'Fault: '; cat "$state/fault"; fi
        printf '\n[Electrical readings and safety checks]\n'
        # Optional diagnostics are independent of the required controller-health check.
        diagnostics=$(timeout -s KILL 8 "$driver" diagnostics 2>/dev/null) || :
        printf '%s\n' "$diagnostics" | awk -F= -v health="$health" -v phase="$phase" '
            {seen[$1]++; if (NF == 2) value[$1]=$2; else invalid[$1]=1}
            function text(key) {return seen[key] == 1 && !invalid[key] ? value[key] : "Unavailable"}
            function numeric(key, signed, low, high, item) {
                item=text(key)
                return length(item) <= 11 && (signed ? item ~ /^-?[0-9]+$/ : item ~ /^[0-9]+$/) && item + 0 >= low && item + 0 <= high
            }
            function boolean(key) {return numeric(key, 0, 0, 1) ? (value[key] == 1 ? "Yes" : "No") : "Unavailable"}
            END {
                current=numeric("current_ua", 1, -2147483647, 2147483647)
                voltage=numeric("voltage_uv", 0, 1, 2147483647)
                if (current) printf "Battery current: %.1f mA (%s)\n", value["current_ua"] / 1000, (value["current_ua"] < 0 ? "discharging" : (value["current_ua"] > 0 ? "charging" : "zero reported"))
                else print "Battery current: Unavailable"
                if (voltage) printf "Battery voltage: %.3f V\n", value["voltage_uv"] / 1000000
                else print "Battery voltage: Unavailable"
                if (current && voltage) printf "Estimated battery power: %.1f mW (sequential battery readings)\n", value["current_ua"] * value["voltage_uv"] / 1000000000
                else print "Estimated battery power: Unavailable"
                if (numeric("profile_fcc_ua", 0, 0, 4500000)) printf "Battery FCC vote: %.0f mA\n", value["profile_fcc_ua"] / 1000
                else print "Battery FCC vote: Unavailable"
                if (numeric("main_fcc_ua", 0, 0, 4500000)) printf "Main FCC parameter: %.0f mA\n", value["main_fcc_ua"] / 1000
                else print "Main FCC parameter: Unavailable"
                condition=text("battery_health")
                printf "Battery condition: %s\n", (length(condition) <= 64 && condition ~ /^[A-Za-z ]+$/ ? condition : "Unavailable")
                printf "JEITA enabled: %s\n", boolean("jeita")
                selinux=text("selinux")
                printf "SELinux: %s\n", (selinux ~ /^(Enforcing|Permissive|Disabled)$/ ? selinux : "Unavailable")
                kernel=text("kernel_match")
                printf "Kernel build: %s\n", (kernel ~ /^(Verified|Unverified)$/ ? kernel : "Unavailable")
                release=text("kernel_release")
                printf "Kernel release: %s\n", (length(release) <= 128 && release ~ /^[A-Za-z0-9._+-]+$/ ? release : "Unavailable")
                printf "ROM provider enabled: %s\nROM service enabled: %s\n", boolean("rom_enabled"), boolean("rom_service_enabled")
                if (numeric("rom_limit", 0, 1, 100)) printf "ROM limit: %s%%\n", value["rom_limit"]; else print "ROM limit: Unavailable"
                if (numeric("rom_mode", 0, 1, 3)) printf "ROM mode: %s\n", value["rom_mode"]; else print "ROM mode: Unavailable"
                policy="Unavailable"
                if (numeric("rom_enabled", 0, 0, 1) && numeric("rom_service_enabled", 0, 0, 1) && numeric("rom_service_active", 0, 0, 1) && numeric("rom_limit", 0, 1, 100) && numeric("rom_mode", 0, 1, 3)) {
                    policy="Not evaluated while control is inactive"
                    if (health == "Working") {
                        expected=phase == "Released" ? 1 : 0
                        if (value["rom_enabled"] == expected && value["rom_service_enabled"] == expected && value["rom_service_active"] == expected && value["rom_limit"] == 70 && value["rom_mode"] == 3)
                            policy=expected ? "Matches restored stock policy" : "Matches active override"
                        else policy="Conflict detected"
                    }
                }
                printf "ROM policy check: %s (enabled, mode, and limit only)\n", policy
            }
        ' ;;
    *) exit 2 ;;
esac
