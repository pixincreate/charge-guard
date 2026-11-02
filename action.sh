#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
# The Magisk Action button only reads diagnostics.
MODDIR=$(CDPATH='' cd -- "${0%/*}" && pwd -P) || exit 1
exec sh "$MODDIR/display.sh" report /data/adb/lavender-battery-guard "$MODDIR" "$MODDIR/device.sh"
