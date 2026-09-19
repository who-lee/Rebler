#!/system/bin/sh
# Rebler-Boot - action
MODPATH="${0%/*}"
. "$MODPATH/common_func.sh"

echo "================================"
echo "  Rebler-Boot v1.0"
echo "  Standalone companion to Rebler"
echo "================================"
echo ""
echo "Cmdline scrubbed: yes (or skipped if kernel refused)"
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
