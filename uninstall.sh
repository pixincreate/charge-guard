#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
MODDIR=${0%/*}
STATE=/data/adb/lavender-battery-guard
if [ -f "$STATE/bin/runtime.sh" ]; then
    sh "$STATE/bin/runtime.sh" stop "$STATE" "$STATE/bin/device.sh" "$MODDIR"
fi
