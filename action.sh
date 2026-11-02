#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
# The Magisk Action button only reads diagnostics.
MODDIR=${0%/*}
exec sh "$MODDIR/display.sh" report /data/adb/lavender-battery-guard "$MODDIR" "$MODDIR/device.sh"
