#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
# Run in a new session. A timeout kills the whole operation group.
set -u
[ "$#" -ge 1 ] || exit 2
if [ -x /system/bin/ps ]; then
    group=$(/system/bin/ps -o PGID= -p "$$") || exit 2
else
    group=$(/bin/ps -o pgid= -p "$$") || exit 2
fi
[ "$(printf '%s' "$group" | tr -d '[:space:]')" = "$$" ] || exit 2
trap 'kill -KILL "-$$"' HUP INT TERM
"$@" &
child=$!
wait "$child"
