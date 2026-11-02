#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
# Verified lavender / SouthWest-NG charging interface. No direct main/input writes.
set -u
umask 077
B=/sys/class/power_supply/battery
M=/sys/class/power_supply/main
U=/sys/class/power_supply/usb
URI=content://lineagesettings/system
BUILD=68e104c18f8aa96b3f8d008f58a293e3fbe60099
[ "$#" -ge 1 ] || exit 2
operation=$1
shift
if [ "$operation" = clock ]; then
    read -r uptime _ < /proc/uptime || exit 1
    printf '%s\n' "${uptime%%.*}"
    exit
fi
[ "$(id -u)" = 0 ] && [ "$(getprop ro.product.device)" = lavender ] || exit 1
boot() { cat /proc/sys/kernel/random/boot_id; }
kernel() {
    notes=$(od -An -tx1 -v /sys/kernel/notes | tr -d ' \n') || return 1
    case "$notes" in *"040000001400000003000000474e5500$BUILD"*) return 0 ;; *) return 1 ;; esac
}
node() {
    [ "$(stat -c '%u %g' "$B/constant_charge_current_max")" = '0 0' ] || return 1
    case "$(stat -c %a "$B/constant_charge_current_max")" in 444|644) ;; *) return 1 ;; esac
}
number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
compatible() {
    kernel && node && [ "$(getprop ro.build.version.sdk)" = 37 ] &&
        [ "$(getenforce)" = Enforcing ] && [ "$(cat "$B/sw_jeita_enabled")" = 1 ] &&
        [ "$(cat "$M/fcc_stepper_enable")" = 0 ] &&
        [ -r "$M/constant_charge_current_max" ] && [ -r "$U/online" ]
}
setting() {
    output=$(timeout -s KILL 3 /system/bin/content query --user 0 --uri "$URI/$1" --projection value) || return 1
    case "$output" in
        'Row: 0 value='*) printf '%s\n' "${output#Row: 0 value=}" ;;
        'No result found.') printf 'absent\n' ;;
        *) return 1 ;;
    esac
}
enabled() {
    [ "$(setting charging_control_enabled)" = "$1" ] || return 1
    service=$(timeout -s KILL 3 /system/bin/dumpsys lineagehealth) || return 1
    if [ "$1" = 1 ]; then expected=true; else expected=false; fi
    [ "$(printf '%s\n' "$service" | awk '$1 == "Enabled:" {print $2; exit}')" = "$expected" ] &&
        [ "$(printf '%s\n' "$service" | awk '$1 == "mIsEnabled:" {print $2; exit}')" = "$expected" ]
}
set_enabled() {
    timeout -s KILL 3 /system/bin/content insert --user 0 --uri "$URI" \
        --bind name:s:charging_control_enabled --bind "value:s:$1" >/dev/null || return 1
    enabled "$1"
}
field() { awk -F= -v key="$1" '$1 == key {print $2}' "$journal"; }
validate() {
    [ "$(stat -c '%a %u %g' "$journal")" = '600 0 0' ] || return 1
    awk -F= '
        NF != 2 || seen[$1]++ {exit 1}
        $1 == "boot" {if ($2 !~ /^[a-f0-9-]+$/ || length($2) != 36) exit 1; next}
        $1 == "kernel" {if ($2 !~ /^[a-f0-9]+$/ || length($2) != 40) exit 1; next}
        $1 == "start" || $1 == "target" {if ($2 != "absent" && $2 !~ /^[0-9]+$/) exit 1; next}
        $1 !~ /^(schema|fcc|mode|enabled|limit|controlmode)$/ || $2 !~ /^[0-9]+$/ {exit 1}
        END {if (NR != 10) exit 1}
    ' "$journal" || return 1
    [ "$(field schema) $(field mode) $(field enabled) $(field limit) $(field controlmode) $(field kernel)" = "1 444 1 70 3 $BUILD" ] || return 1
    original=$(field fcc) || return 1
    [ "$original" -gt 0 ] && [ "$original" -le 4500000 ] && [ "$((original % 25000))" -eq 0 ]
}
policy() {
    [ "$(setting charging_control_charging_limit)" = "$(field limit)" ] &&
        [ "$(setting charging_control_mode)" = "$(field controlmode)" ] &&
        [ "$(setting charging_control_start_time)" = "$(field start)" ] &&
        [ "$(setting charging_control_target_time)" = "$(field target)" ] && enabled "$1"
}
write_fcc() {
    requested=$1
    node || return 1
    [ "$requested" = 0 ] || [ "$requested" = "$original" ] || return 1
    chmod u+w "$B/constant_charge_current_max" || return 1
    write_status=0
    printf '%s\n' "$requested" > "$B/constant_charge_current_max" || write_status=1
    chmod "$(field mode)" "$B/constant_charge_current_max" || write_status=1
    [ "$write_status" -eq 0 ] && [ "$(cat "$B/constant_charge_current_max")" = "$requested" ]
}
hardware() {
    actual=$(cat "$M/constant_charge_current_max") || return 1
    number "$actual" || return 1
    if [ "$1" = 0 ]; then [ "$actual" -eq 0 ]; else [ "$actual" -le "$original" ]; fi
}
zero() {
    write_fcc 0 || return 1
    attempts=5
    while [ "$attempts" -gt 0 ]; do
        hardware 0 && return 0
        attempts=$((attempts - 1))
        sleep 1 || return 1
    done
    return 1
}
limit_ready() {
    attempts=5
    while [ "$attempts" -gt 0 ]; do
        if sh "${0%/*}/recovery-ready.sh" "$(cat "$B/capacity")" "$(cat "$U/present")" \
            "$(cat "$B/input_suspend")" "$(field limit)"; then return 0; fi
        attempts=$((attempts - 1))
        sleep 1 || return 1
    done
    return 1
}
diagnostic_number() {
    diagnostic_value=$(cat "$2" 2>/dev/null) || diagnostic_value=Unavailable
    diagnostic_digits=$diagnostic_value
    [ "${3:-}" != signed ] || diagnostic_digits=${diagnostic_value#-}
    case "$diagnostic_digits" in ''|*[!0-9]*) diagnostic_value=Unavailable ;;
        *) [ "${#diagnostic_digits}" -le 10 ] && [ "$diagnostic_digits" -le 2147483647 ] || diagnostic_value=Unavailable ;;
    esac
    printf '%s=%s\n' "$1" "$diagnostic_value"
}
case "$operation" in
    boot) boot ;;
    compatible) compatible ;;
    diagnostics)
        # Optional, read-only observations. Never use USB input-current ADC as adapter power.
        diagnostic_number current_ua "$B/current_now" signed
        diagnostic_number voltage_uv "$B/voltage_now"
        diagnostic_number profile_fcc_ua "$B/constant_charge_current_max"
        diagnostic_number main_fcc_ua "$M/constant_charge_current_max"
        diagnostic_number jeita "$B/sw_jeita_enabled"
        diagnostic_health=$(cat "$B/health" 2>/dev/null) || diagnostic_health=Unavailable
        printf 'battery_health=%s\n' "$diagnostic_health"
        printf 'selinux=%s\n' "$(getenforce 2>/dev/null || printf Unavailable)"
        if kernel; then printf 'kernel_match=Verified\n'; else printf 'kernel_match=Unverified\n'; fi
        printf 'kernel_release=%s\n' "$(uname -r 2>/dev/null || printf Unavailable)"
        printf 'rom_enabled=%s\n' "$(setting charging_control_enabled 2>/dev/null || printf Unavailable)"
        diagnostic_service=$(timeout -s KILL 3 /system/bin/dumpsys lineagehealth 2>/dev/null) || diagnostic_service=
        printf '%s\n' "$diagnostic_service" | awk '
            ($1 == "Enabled:" || $1 == "mIsEnabled:" || $1 == "Mode:" || $1 == "Limit:") && !($1 in value) {value[$1]=$2}
            function boolean(label) {
                if (value[label] == "true") return "1"
                if (value[label] == "false") return "0"
                return "Unavailable"
            }
            function number(label) {return value[label] ~ /^[0-9]+$/ ? value[label] : "Unavailable"}
            END {
                print "rom_service_enabled=" boolean("Enabled:")
                print "rom_service_active=" boolean("mIsEnabled:")
                print "rom_mode=" number("Mode:")
                print "rom_limit=" number("Limit:")
            }
        ' ;;
    sensors)
        [ "$(getenforce)" = Enforcing ] && [ "$(cat "$B/sw_jeita_enabled")" = 1 ] &&
            [ "$(cat "$B/health")" = Good ] && node || exit 1
        soc=$(cat "$B/capacity") && present=$(cat "$U/present") && online=$(cat "$U/online") &&
            temperature=$(cat "$B/temp") || exit 1
        number "$soc" && number "$present" && number "$online" && number "$temperature" || exit 1
        if [ "${1:-Released}" != Released ]; then
            journal=$2
            validate || exit 1
            if [ "$1" = Holding ]; then target=0; else target=$original; fi
            [ "$(stat -c %a "$B/constant_charge_current_max")" = 444 ] &&
                [ "$(cat "$B/constant_charge_current_max")" = "$target" ] && hardware "$target" || exit 1
            if [ "$present" = 1 ]; then
                [ "$(cat "$B/input_suspend")" = 0 ] && [ "$online" = 1 ] || exit 1
            fi
        fi
        printf '%s %s %s %s\n' "$soc" "$present" "$online" "$temperature" ;;
    snapshot)
        journal=$1
        compatible && [ "$(stat -c %a "$B/constant_charge_current_max")" = 444 ] || exit 1
        original=$(cat "$B/constant_charge_current_max") || exit 1
        # Construct data in a private temporary file; the runtime commits it atomically.
        {
            echo schema=1
            echo "boot=$(boot)"
            echo "kernel=$BUILD"
            echo "fcc=$original"
            echo mode=444
            echo "enabled=$(setting charging_control_enabled)"
            echo "limit=$(setting charging_control_charging_limit)"
            echo "controlmode=$(setting charging_control_mode)"
            echo "start=$(setting charging_control_start_time)"
            echo "target=$(setting charging_control_target_time)"
        } > "$journal" || exit 1
        validate && policy 1 ;;
    acquire|hold|charge|policy|recover)
        journal=$1
        validate || exit 1
        if [ "$operation" = recover ]; then
            same_boot=0
            if [ "$(field boot)" = "$(boot)" ]; then
                kernel && node || exit 1
                same_boot=1
                zero || echo 'Zero-current verification fails during recovery; restore the ROM limit.' >&2
            fi
            # Restore persistent policy even after a kernel update. Do not replay old FCC.
            set_enabled "$(field enabled)" || exit 1
            limit_ready || exit 1
            policy 1 || exit 1
            if [ "$same_boot" = 1 ]; then
                write_fcc "$original" && hardware "$original" || exit 1
            fi
            exit 0
        fi
        compatible && [ "$(field boot)" = "$(boot)" ] || exit 1
        case "$operation" in
            acquire)
                policy 1 && zero && set_enabled 0 || exit 1
                attempts=5
                while [ "$attempts" -gt 0 ]; do
                    if [ "$(cat "$U/present")" = 1 ] && [ "$(cat "$U/online")" = 1 ] &&
                        [ "$(cat "$B/input_suspend")" = 0 ]; then exit 0; fi
                    attempts=$((attempts - 1))
                    sleep 1 || exit 1
                done
                exit 1 ;;
            hold) policy 0 && zero ;;
            charge) policy 0 && write_fcc "$original" && hardware "$original" ;;
            policy) policy 0 ;;
        esac ;;
    *) exit 2 ;;
esac
