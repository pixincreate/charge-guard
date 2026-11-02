#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 PiX (pixincreate)
[ "$BOOTMODE" = true ] || abort 'Install this module from the Magisk app.'
for legacy in /data/adb/modules/lavender_battery_guard /data/adb/modules_update/lavender_battery_guard; do
    [ ! -d "$legacy" ] || abort 'Remove the old module and reboot before installing Charge Guard.'
done
ui_print '- Checking the lavender charging interface'
sh "$MODPATH/device.sh" compatible || abort 'Unsupported kernel, ROM, or charging interface. No charging settings change.'
set_perm_recursive "$MODPATH" 0 0 0755 0644
for script in service.sh uninstall.sh runtime.sh device.sh bounded-command.sh recovery-ready.sh display.sh action.sh; do
    set_perm "$MODPATH/$script" 0 0 0755
done
ui_print '- Stop charging at 70%; resume at 65%'
ui_print '- Reboot to start. Thermal protections remain enabled.'
