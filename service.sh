#!/system/bin/sh
# Rebler - service.sh
# Late-start, after boot is mostly done. We:
#   1. Tighten property state once more
#   2. Make sure flags + allowlist exist for the WebUI

MODPATH="${0%/*}"
. "$MODPATH/common_func.sh"

log_info "=== service.sh v1.3.1 start ==="

# Init first so the summary below reports real state (post-fs-data.sh
# does flags -> allowlist -> summary in this same order).
allowlist_init
ensure_all_flags
boot_summary

if is_flag_enabled spoof;   then spoof_boot_state;   fi
if is_flag_enabled keystore; then hide_keystore_leaks; fi
if is_flag_enabled zygisk;   then scrub_root_paths;    fi

log_info "=== service.sh v1.3.1 complete ==="
exit 0