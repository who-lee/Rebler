#!/system/bin/sh
# Rebler-Boot - customize
MODPATH="${0%/*}"

[ "$(id -u)" != "0" ] && abort "Rebler-Boot: not root"

ui_print "============================================"
ui_print "  Rebler-Boot v1.0 - Bootloader Hide Companion"
ui_print "  Author: lee-muriithi-kingori"
ui_print "============================================"
ui_print ""
ui_print "I built Rebler-Boot as a companion to Rebler. It goes one level"
ui_print "deeper on bootloader-state signals at boot time:"
ui_print "  - Sets the same verified-boot chain as Rebler"
ui_print "  - Strips verified-boot error markers"
ui_print "  - Bind-mounts a clean /proc/cmdline so apps reading it"
ui_print "    directly do not see androidboot.unlocked=1"
ui_print ""
ui_print "  What this module cannot do:"
ui_print "    * It does not defeat hardware-backed Play Integrity"
ui_print "      attestation. STRONG integrity requires a real keybox"
ui_print "      from your own device. Use TrickyStore."
ui_print ""

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh"      0 0 0755
set_perm "$MODPATH/customize.sh"    0 0 0755
set_perm "$MODPATH/uninstall.sh"    0 0 0755
set_perm "$MODPATH/action.sh"       0 0 0755
set_perm "$MODPATH/system.prop"     0 0 0644
set_perm "$MODPATH/module.prop"     0 0 0644
set_perm "$MODPATH/common_func.sh"  0 0 0644

touch /data/local/tmp/ReblBoot.log 2>/dev/null
chmod 644 /data/local/tmp/ReblBoot.log 2>/dev/null

ui_print ""
ui_print "Rebler-Boot installed. Reboot for changes to apply."
ui_print "Order with Rebler does not matter: both sides use"
ui_print "resetprop_if_diff, so whichever post-fs-data runs second"
ui_print "converges on the same values."
ui_print ""
ui_print "Community: https://t.me/lestramk"
exit 0
