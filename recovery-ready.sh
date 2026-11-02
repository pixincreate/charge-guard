#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
# Decide from observed state, not just the provider's enabled flag.
[ "$#" -eq 4 ] || exit 2
for value in "$@"; do
    case "$value" in ''|*[!0-9]*) exit 2 ;; esac
done
[ "$1" -le 100 ] && [ "$2" -le 1 ] && [ "$3" -le 1 ] && [ "$4" -gt 0 ] && [ "$4" -le 100 ] || exit 2
[ "$2" -eq 0 ] || [ "$1" -lt "$4" ] || [ "$3" -eq 1 ]
