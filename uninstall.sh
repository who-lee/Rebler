#!/system/bin/sh
# Rebler - uninstall
# Cleanly remove everything we put down before the module dir is deleted.
#
# Note: the root manager deletes the whole module directory as part of
# uninstalling, so allowing a "keep allowlist for reinstall" path would
# be theater — that file is gone anyway. We only clear runtime state
# (logs, flags, live state) that lives alongside the module.

MODPATH="${0%/*}"
LOG_FILE=/data/local/tmp/Rebler.log

log_msg() {
    level="$1"; shift
    stamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 1970-01-01)
    echo "[$stamp] [$level] Rebler: $*" >> "$LOG_FILE" 2>/dev/null
}

log_msg "INFO" "Uninstalling"

# Runtime state files (flags and live state).
for s in "$MODPATH"/.state_* "$MODPATH"/.flag_*; do
    [ -f "$s" ] && rm -f "$s" 2>/dev/null
done

log_msg "INFO" "Uninstall complete"
exit 0