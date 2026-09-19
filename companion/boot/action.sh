#!/system/bin/sh
# Rebler-Boot - action
MODPATH="${0%/*}"
. "$MODPATH/common_func.sh"

echo "================================"
echo "  Rebler-Boot v1.0"
echo "  Standalone companion to Rebler"
echo "================================"
echo ""
# Report what is actually true: check the live cmdline for the dirty
# tokens and the log for the bind result. Never print a blanket "yes".
dirty=""
if grep -qE 'androidboot\.unlocked=1|androidboot\.verifier=disabled' /proc/cmdline 2>/dev/null; then
    dirty=" (dirty tokens still visible — kernel refused the bind, see log)"
fi
if grep -q "Bound clean cmdline" /data/local/tmp/ReblBoot.log 2>/dev/null; then
    echo "Cmdline scrubbed: yes$dirty"
elif grep -q "Could not bind-mount /proc/cmdline" /data/local/tmp/ReblBoot.log 2>/dev/null; then
    echo "Cmdline scrubbed: no — kernel refused the bind, upstream cmdline visible"
else
    echo "Cmdline scrubbed: unknown (no boot log yet — reboot first)$dirty"
fi
echo "Verified-boot state:"
for k in ro.boot.flash.locked ro.boot.verifiedbootstate \
         ro.boot.vbmeta.device_state ro.secureboot.lockstate; do
    v=$(resetprop "$k" 2>/dev/null)
    echo "  $k=$v"
done
echo ""
echo "For Play Integrity STRONG see:"
echo "  https://github.com/5ec1cff/TrickyStore"
echo ""
echo "Community: https://t.me/lestramk"
exit 0
