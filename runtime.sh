#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
# shellcheck shell=ksh
# The controller and every operation inherit the writer lock. Recovery waits for it.
if [ -n "${KSH_VERSION:-}" ]; then
    # Android mksh otherwise closes descriptors opened by exec before child commands.
    set -o posix
fi
if [ -x /system/bin/timeout ]; then
    # Keep setsid attached to the wait without a detached lock-holding watchdog.
    timeout() { /system/bin/timeout --foreground "$@"; }
fi
set -u
umask 077
[ "$#" -ge 4 ] || exit 2
command=$1
state=$2
driver=$3
module=$4
poll=${5:-5}
lease=${6:-30}
case "$state:$driver:$module" in /*:/*:/*) ;; *) exit 2 ;; esac
case "$poll:$lease" in *[!0-9:]*|:*|*:) exit 2 ;; esac
[ "$poll" -ge 1 ] && [ "$lease" -ge 3 ] && [ "$lease" -le 120 ] || exit 2
mkdir -p "$state" || exit 1
chmod 700 "$state" || exit 1
journal=$state/journal
clock() { timeout -s KILL 2 "$driver" clock; }
operation() {
    seconds=$1
    shift
    timeout -s TERM -k 1 "$seconds" setsid sh "${0%/*}/bounded-command.sh" "$driver" "$@"
}
identity() {
    if [ -r "/proc/$1/stat" ]; then
        sed 's/^.*) //' "/proc/$1/stat" | awk '{ print $20 }'
    else
        /bin/ps -o lstart= -p "$1" | awk '{$1=$1; print}'
    fi
}
fault() { printf '%s\n' "$*" > "$state/fault"; }
status() {
    printf '%s\n' "$1" > "$state/status" || return 1
    # Reporting is bounded and best effort; it must not change control decisions.
    if [ "$1" != "${display_phase:-}" ] || [ "$((${now:-0} - ${display_checked:-0}))" -ge 60 ]; then
        display_phase=$1
        display_checked=${now:-0}
        timeout -s TERM -k 1 2 setsid sh "${0%/*}/bounded-command.sh" sh "${0%/*}/display.sh" \
            publish "$state" "$module" "$1" || printf 'The module-card status cannot update.\n' >&2
    fi
    return 0
}
recover() {
    [ -f "$journal" ] || return 0
    if operation 20 recover "$journal"; then
        rm -f "$journal"
    else
        fault 'Recovery fails. The journal is retained. Inspect the charging state.'
        return 1
    fi
}
stopping() { [ -e "$state/stop" ] || [ -e "$module/disable" ] || [ -e "$module/remove" ]; }
heartbeat() {
    clock > "$state/$1.next" && mv "$state/$1.next" "$state/$1"
}
guard_check() {
    now=$(clock) || return 1
    read -r guard_time < "$state/guard-heartbeat" || return 1
    case "$now:$guard_time" in *[!0-9:]*|:*|*:) return 1 ;; esac
    [ "$now" -ge "$guard_time" ] && [ "$((now - guard_time))" -lt "$lease" ] &&
        kill -0 "$guard_pid" 2>/dev/null && [ "$(identity "$guard_pid")" = "$guard_identity" ]
}
progress() { guard_check && heartbeat controller-heartbeat; }
controller_exit() {
    exit_status=$1
    trap - EXIT
    trap ':' HUP INT TERM
    recover || exit_status=1
    if [ "$exit_status" -ne 0 ]; then
        fault "Controller stops with status $exit_status."
        status Fault
    fi
    exit "$exit_status"
}
control() {
    exec 9> "$state/writer.lock"
    flock -n 9 || return 1
    trap 'controller_exit $?' EXIT
    trap 'exit 1' HUP INT TERM
    read -r guard_pid guard_identity < "$state/guard"
    last_policy=0
    phase=Released
    while ! stopping; do
        guard_check || return 1
        sample=$(operation 4 sensors "$phase" "$journal") || return 1
        read -r soc present online temperature extra <<EOF
$sample
EOF
        case "$soc:$present:$online:$temperature" in *[!0-9:]*|:*|*:) return 1 ;; esac
        [ -z "$extra" ] && [ "$soc" -le 100 ] && [ "$present" -le 1 ] && [ "$online" -le 1 ] &&
            [ "$temperature" -gt 0 ] && [ "$temperature" -lt 400 ] || return 1
        progress || return 1
        if [ "$present" -eq 0 ]; then
            recover || return 1
            phase=Released
        else
            if [ ! -f "$journal" ]; then
                operation 20 snapshot "$journal.next" && mv "$journal.next" "$journal" || return 1
                progress || return 1
                sync
                progress || return 1
                printf '%s\n' acquire > "$state/intent"
                operation 20 acquire "$journal" || return 1
                progress || return 1
                phase=Holding
                if [ "$soc" -lt 70 ]; then
                    printf '%s\n' charge > "$state/intent"
                    operation 20 charge "$journal" || return 1
                    progress || return 1
                    phase=Charging
                fi
                last_policy=$now
            elif [ "$phase" = Charging ] && [ "$soc" -ge 70 ]; then
                printf '%s\n' hold > "$state/intent"
                operation 20 hold "$journal" || return 1
                progress || return 1
                phase=Holding
            elif [ "$phase" = Holding ] && [ "$soc" -le 65 ]; then
                printf '%s\n' charge > "$state/intent"
                operation 20 charge "$journal" || return 1
                progress || return 1
                phase=Charging
            fi
            if [ "$((now - last_policy))" -ge 60 ]; then
                operation 15 policy "$journal" || return 1
                last_policy=$now
            fi
        fi
        status "$phase"
        progress || return 1
        sleep "$poll" || return 1
    done
}
supervisor_exit() {
    supervisor_status=$1
    trap - EXIT
    trap ':' HUP INT TERM
    if [ "$supervisor_status" -ne 0 ] && [ ! -f "$state/fault" ]; then
        fault "Supervisor stops with status $supervisor_status."
    fi
    if [ -n "${child:-}" ] && kill -0 "$child" 2>/dev/null && [ "$(identity "$child")" = "$child_identity" ]; then
        # Kill only the controller. Its bounded children must keep their timeout and lock.
        kill -KILL "$child" 2>/dev/null || true
    fi
    [ -z "${child:-}" ] || wait "$child" 2>/dev/null || true
    exec 9> "$state/writer.lock"
    if timeout -s KILL 30 flock 9; then
        recover || supervisor_status=1
    else
        fault 'A writer still owns the lock. Recovery does not start concurrently.'
        supervisor_status=1
    fi
    if [ -f "$state/fault" ]; then status Fault; else status Stopped; fi
    exit "$supervisor_status"
}
supervise() {
    exec 8> "$state/supervisor.lock"
    flock -n 8 || return 0
    trap 'supervisor_exit $?' EXIT
    trap 'exit 1' HUP INT TERM
    exec 9> "$state/writer.lock"
    timeout -s KILL 30 flock 9 && recover || return 1
    exec 9>&-
    boot=$(operation 4 boot) || return 1
    if [ ! -f "$state/boot" ] || [ "$(cat "$state/boot")" != "$boot" ]; then
        rm -f "$state/fault" "$state/stop"
        printf '%s\n' "$boot" > "$state/boot"
    fi
    [ ! -f "$state/fault" ] && ! stopping || return 1
    status Starting
    operation 4 compatible || { fault 'Unsupported kernel, ROM, or charging interface.'; return 1; }
    printf '%s %s\n' "$$" "$(identity "$$")" > "$state/guard"
    heartbeat guard-heartbeat && heartbeat controller-heartbeat || return 1
    setsid sh "$0" control "$state" "$driver" "$module" "$poll" "$lease" &
    child=$!
    child_identity=$(identity "$child")
    printf '%s\n' "$child" > "$state/controller.pid"
    while kill -0 "$child" 2>/dev/null; do
        stopping && return 0
        heartbeat guard-heartbeat || return 1
        now=$(clock) || return 1
        read -r checked < "$state/controller-heartbeat" || return 1
        case "$now:$checked" in *[!0-9:]*|:*|*:) return 1 ;; esac
        if [ "$now" -lt "$checked" ] || [ "$((now - checked))" -ge "$lease" ]; then
            fault 'The controller heartbeat expires.'
            return 1
        fi
        sleep "$poll" || return 1
    done
    wait "$child"
}
case "$command" in
    supervise) supervise ;;
    control) control ;;
    stop)
        touch "$state/stop"
        exec 8> "$state/supervisor.lock"
        timeout -s KILL 45 flock 8 || exit 1
        exec 9> "$state/writer.lock"
        timeout -s KILL 30 flock 9 && recover ;;
    *) exit 2 ;;
esac
