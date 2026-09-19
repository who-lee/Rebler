#!/system/bin/sh
# Rox2 - shared functions
# I keep these POSIX-compatible so they run on bash, ash, mksh — whatever Android gives me.

MODPATH="${0%/*}"
[ -z "$MODPATH" ] && MODPATH=/data/adb/modules/Rox2

LOG_FILE=/data/local/tmp/Rox2.log

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_msg() {
    level="$1"; shift
    stamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 1970-01-01)
    safe=$(printf '%s' "$*" | tr -cd '[:print:]\n ')
    echo "[$stamp] [$level] Rox2: $safe" >> "$LOG_FILE" 2>/dev/null
    log -t Rox2 "[$level] $*" 2>/dev/null || true
}
log_info()  { log_msg INFO  "$@"; }
log_warn()  { log_msg WARN  "$@"; }
log_error() { log_msg ERROR "$@"; }

# ---------------------------------------------------------------------------
# Root manager detection
# ---------------------------------------------------------------------------
detect_root_manager() {
    if [ -n "${KSU:-}" ] && [ "$KSU" = "true" ]; then echo "kernelsu"
    elif [ -n "${APATCH:-}" ] && [ "$APATCH" = "true" ]; then echo "apatch"
    elif [ -n "${MAGISK_VER_CODE:-}" ]; then echo "magisk"
    else echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Boolean state flags (read by both shell and Zygisk module)
# ---------------------------------------------------------------------------
write_state() {
    key="$1"; value="$2"
    file="$MODPATH/.state_$key"
    tmp="$file.tmp.$$"
    echo "$value" > "$tmp" 2>/dev/null || return 1
    mv "$tmp" "$file" 2>/dev/null || { cat "$tmp" > "$file" && rm -f "$tmp"; }
    chmod 644 "$file" 2>/dev/null
    return 0
}
read_state() {
    key="$1"; default="${2:-}"
    file="$MODPATH/.state_$key"
    [ -r "$file" ] && { cat "$file" 2>/dev/null || echo "$default"; } || echo "$default"
}

# ---------------------------------------------------------------------------
# resetprop helpers
# ---------------------------------------------------------------------------
resetprop_safe() {
    target="$1"; value="$2"
    tries=0
    while [ $tries -lt 5 ]; do
        if resetprop -n "$target" "$value" 2>/dev/null; then return 0; fi
        tries=$((tries + 1))
        sleep 0.2
    done
    log_warn "Could not resetprop $target=$value"
    return 1
}

resetprop_if_diff() {
    target="$1"; value="$2"
    current=$(resetprop "$target" 2>/dev/null || true)
    if [ "$current" != "$value" ]; then
        resetprop_safe "$target" "$value"
    fi
}

resetprop_if_match() {
    target="$1"; contains="$2"; value="$3"
    current=$(resetprop "$target" 2>/dev/null || true)
    if [ -n "$current" ] && printf '%s' "$current" | grep -q "$contains"; then
        resetprop_safe "$target" "$value"
    fi
}

delprop_if_exists() {
    target="$1"
    [ -z "$target" ] && return 0
    current=$(resetprop "$target" 2>/dev/null || true)
    [ -z "$current" ] && return 0
    # resetprop --delete makes the property invisible to readers. The old
    # -c flag now means "compact" in Magisk 27's Rust resetprop, so --delete
    # is the one that actually clears the property.
    resetprop --delete "$target" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Feature flags driven by .flag_* files (WebUI toggles them)
#   .flag_spoof       - boot/property spoofing on/off   (default 1)
#   .flag_keystore    - keystore leak scrub            (default 1)
#   .flag_zygisk      - Zygisk mount-namespace hide    (default 1)
#
# Manager-app hiding is NOT a flag: it lives in allowlist.json as
# `deny_root_manager` so there is exactly one source of truth.
# ---------------------------------------------------------------------------
ensure_flag() {
    key="$1"; default="${2:-1}"
    file="$MODPATH/.flag_$key"
    [ -f "$file" ] || echo "$default" > "$file"
    chmod 644 "$file" 2>/dev/null
}
is_flag_enabled() {
    key="$1"
    file="$MODPATH/.flag_$key"
    if [ -f "$file" ]; then
        [ "$(cat "$file" 2>/dev/null)" = "1" ]
    else
        return 0
    fi
}
set_flag() {
    key="$1"; value="$2"
    echo "$value" > "$MODPATH/.flag_$key"
    chmod 644 "$MODPATH/.flag_$key" 2>/dev/null
}
ensure_all_flags() {
    ensure_flag spoof        "1"
    ensure_flag keystore     "1"
    ensure_flag zygisk       "1"
}

# ---------------------------------------------------------------------------
# Allowlist (default-deny) + manager-toggle
# ---------------------------------------------------------------------------
ALLOWLIST_FILE="$MODPATH/allowlist.json"
HIDE_MGR_DEFAULT_PKGS="com.topjohnwu.magisk me.weishu.kernelsu me.bmax.apatch org.lsposed.manager de.robv.android.xposed.installer"

allowlist_init() {
    [ -f "$ALLOWLIST_FILE" ] || echo '{"allow":[],"deny_root_manager":false,"version":1}' > "$ALLOWLIST_FILE"
    chmod 644 "$ALLOWLIST_FILE" 2>/dev/null
}

# Returns "1" if the package is on the allowlist, "0" otherwise. Manager
# packages are auto-allowed only when the user has not toggled
# `deny_root_manager` in the file.
is_allowlisted() {
    pkg="$1"
    [ -z "$pkg" ] && { echo "0"; return; }
    allowlist_init
    if grep -q "\"$pkg\"" "$ALLOWLIST_FILE" 2>/dev/null; then
        echo "1"; return
    fi
    # Check the "deny_root_manager" flag. If false, root manager packages
    # stay auto-allowed so the manager can run.
    deny=$(grep -o '"deny_root_manager":[ ]*\(true\|false\)' "$ALLOWLIST_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ')
    if [ "$deny" = "false" ]; then
        for mp in $HIDE_MGR_DEFAULT_PKGS; do
            [ "$pkg" = "$mp" ] && { echo "1"; return; }
        done
    fi
    echo "0"
}

# True when the user turned on "hide manager apps". It is stored as
# deny_root_manager in allowlist.json (the single source of truth for
# manager handling). When off, manager packages keep their auto-allow.
is_manager_hidden() {
    [ -f "$ALLOWLIST_FILE" ] || return 1
    deny=$(grep -o '"deny_root_manager":[ ]*\(true\|false\)' "$ALLOWLIST_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ')
    [ "$deny" = "true" ]
}

# Rebuild allowlist.json from the "allow" array on disk, optionally adding
# $1 and removing $2. Rewriting the whole array keeps the file valid JSON
# no matter how it is formatted (WebUI writes it pretty-printed).
rebuild_allowlist() {
    add_pkg=""; rm_pkg=""
    [ -n "${2:-}" ] && { add_pkg="$1"; rm_pkg="$2"; }
    [ -n "${1:-}" ] && [ -z "${2:-}" ] && add_pkg="$1"
    [ -z "${1:-}" ] && [ -n "${2:-}" ] && rm_pkg="$2"
    tmp="$ALLOWLIST_FILE.tmp.$$"
    awk -v add_pkg="$add_pkg" -v rm_pkg="$rm_pkg" '
        { buf = buf $0 "\n" }
        END {
            # Locate the "allow" array.
            h = index(buf, "\"allow\"")
            if (h == 0) { printf "%s", buf; exit }
            s = index(substr(buf, h), "[") + h - 1
            e = index(substr(buf, s), "]")
            if (e == 0) { printf "%s", buf; exit }
            e = s + e - 1

            # Collect the current package tokens (bounded to the array,
            # so the closing ] can never be escaped).
            n = 0; p = s + 1
            while (p < e) {
                seg = substr(buf, p, e - p)
                qs = index(seg, "\"")
                if (qs == 0) break
                sp = p + qs - 1
                seg2 = substr(buf, sp + 1, e - sp - 1)
                qe = index(seg2, "\"")
                if (qe == 0) break
                ep = sp + qe
                tok[n++] = substr(buf, sp + 1, ep - sp - 1)
                p = ep + 1
            }

            # Apply the add (only if new) and remove (drop every match).
            if (add_pkg != "") {
                seen = 0
                for (i = 0; i < n; i++) if (tok[i] == add_pkg) seen = 1
                if (!seen) tok[n++] = add_pkg
            }
            if (rm_pkg != "") {
                m = 0
                for (i = 0; i < n; i++) if (tok[i] != rm_pkg) tok[m++] = tok[i]
                n = m
            }

            # Preserve the deny_root_manager setting.
            deny = "true"
            d = index(buf, "\"deny_root_manager\"")
            if (d > 0 && index(substr(buf, d), "false") > 0) deny = "false"

            printf "{\"allow\":["
            for (i = 0; i < n; i++) {
                if (i > 0) printf ","
                printf "\"" tok[i] "\""
            }
            printf "],\"deny_root_manager\":%s,\"version\":1}\n", deny
        }
    ' "$ALLOWLIST_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$ALLOWLIST_FILE" 2>/dev/null
    chmod 644 "$ALLOWLIST_FILE" 2>/dev/null
}

allowlist_add() {
    pkg="$1"
    [ -z "$pkg" ] && return 1
    allowlist_init
    if grep -q "\"$pkg\"" "$ALLOWLIST_FILE" 2>/dev/null; then
        return 0
    fi
    rebuild_allowlist "$pkg" ""
    log_info "Allowlist add: $pkg"
}

allowlist_remove() {
    pkg="$1"
    [ -z "$pkg" ] && return 1
    [ ! -f "$ALLOWLIST_FILE" ] && return 0
    rebuild_allowlist "" "$pkg"
    log_info "Allowlist remove: $pkg"
}

# ---------------------------------------------------------------------------
# Boot-time property cleanup. v1.2 only sets values we can stand behind:
# universal Google constants and stock states, no guessed placeholders.
# ---------------------------------------------------------------------------
spoof_boot_state() {
    log_info "Spoofing boot/locked state"
    for key in \
        ro.boot.flash.locked ro.boot.verifiedbootstate ro.boot.veritymode \
        ro.boot.vbmeta.device_state ro.boot.vbmeta.avb_version \
        ro.boot.vbmeta.hash_alg \
        ro.secureboot.lockstate \
        sys.oem_unlock_allowed ro.boot.mode ro.bootmode \
        ro.debuggable ro.secure ro.adb.secure \
        ro.boot.selinux ro.boot.secureboot \
        vendor.boot.flash.locked vendor.boot.verifiedbootstate \
        vendor.boot.vbmeta.device_state; do
        val=$(grep "^$key=" "$MODPATH/system.prop" 2>/dev/null | cut -d= -f2- | head -1)
        [ -n "$val" ] && resetprop_safe "$key" "$val"
    done
    for prop in $(resetprop 2>/dev/null | grep -oE 'ro\..*\.build\.tags' 2>/dev/null); do
        resetprop_safe "$prop" "release-keys"
    done
    for prop in $(resetprop 2>/dev/null | grep -oE 'ro\..*\.build\.type' 2>/dev/null); do
        resetprop_safe "$prop" "user"
    done
    resetprop_if_match ro.boot.mode recovery boot
    resetprop_if_match ro.bootmode recovery boot
    resetprop_if_match vendor.boot.mode recovery boot
    delprop_if_exists ro.boot.verifiedbooterror
    delprop_if_exists ro.boot.verifyerrorpart
    delprop_if_exists ro.boot.verifyerrorcode
    delprop_if_exists ro.build.selinux
    log_info "Boot state spoofed"
}

hide_keystore_leaks() {
    log_info "Stripping keystore/root-solution property leaks"
    for leak in \
        ro.magisk.keystore ro.magisk.hide ro.magisk.flash ro.magisk.monitor \
        ro.ksu.keystore ro.ksu.selinux ro.ksu.internal ro.ksu.busybox \
        ro.apatch.keystore ro.apatch.recovery \
        ro.su_bit ro.debuggable.secure persist.magisk.hide \
        persist.magisk.monitor ro.magisk.version; do
        delprop_if_exists "$leak"
    done
    log_info "Keystore leaks stripped"
}

is_boot_completed() { [ "$(resetprop sys.boot_completed 2>/dev/null)" = "1" ]; }

boot_summary() {
    rm=$(detect_root_manager)
    log_info "Manager: $rm | Boot: $(is_boot_completed && echo done || echo booting) | Allowlist: $ALLOWLIST_FILE | HideMgr: $(is_manager_hidden)"
}

# ---------------------------------------------------------------------------
# File-system scrub used at boot. We make sure the module paths and the
# root-manager userland app data dirs are gone from the *parent* mount
# namespace so child processes inherit a clean view. The Zygisk layer
# further isolates each process.
# ---------------------------------------------------------------------------
scrub_root_paths() {
    log_info "Scrubbing root-manager storage paths"
    # These are best-effort; umount2 may fail if the path does not exist.
    for target in \
        /data/adb/modules \
        /data/adb/ksu \
        /data/adb/ap \
        /data/adb/magisk \
        /sbin/.magisk \
        /sbin/magisk \
        /data/adb/lspd \
        /data/adb/riru \
        /debug_ramdisk; do
        umount2 "$target" 2>/dev/null || true
    done
    log_info "Root storage paths scrubbed"
}
