#!/system/bin/sh
# Rox2 - service.sh
# Late-start, after boot is mostly done. We:
#   1. Tighten property state once more
#   2. Make sure flags + allowlist exist for the WebUI

MODPATH="${0%/*}"
. "$MODPATH/common_func.sh"

log_info "=== service.sh v1.2 start ==="

boot_summary
allowlist_init
ensure_all_flags

if is_flag_enabled spoof;   then spoof_boot_state;   fi
if is_flag_enabled keystore; then hide_keystore_leaks; fi
if is_flag_enabled zygisk;   then scrub_root_paths;    fi

log_info "=== service.sh v1.2 complete ==="
exit 0