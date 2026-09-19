#!/usr/bin/env bash
# Rebler - build.sh
# I built this so the WebUI ZIP could be produced locally without CI.
#
# Behavior:
#   - Runs the validation pass at all times
#   - If ANDROID_NDK_HOME is set, compiles the Zygisk native module and
#     bundles librebler.so into zygisk/<abi>.so for each ABI
#   - Without NDK, the build still produces a valid module ZIP that
#     works on every root manager; the Zygisk layer just falls through
#     to the shell-script path. We deliberately do not invent a fake lib.
#
# Usage:
#   ./build.sh                       # default version (read from module.prop)
#   ./build.sh v1.3                  # explicit version
#   ./build.sh --check-only          # validate but don't package

set -u

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
OUTPUT_DIR="$ROOT_DIR/output"

MODULE_ID="Rebler"
MODULE_NAME="Rebler"
DEFAULT_VERSION="$(grep '^version=' "$ROOT_DIR/module.prop" 2>/dev/null | cut -d= -f2 || echo v1.3)"
VERSION="${1:-$DEFAULT_VERSION}"
VERSION_CODE="$(grep '^versionCode=' "$ROOT_DIR/module.prop" 2>/dev/null | cut -d= -f2)"
CHECK_ONLY=false
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=true

# ---------------------------- helpers ---------------------------------------
log()   { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
ok()    { printf '\033[0;32m[OK]\033[0m   %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()   { printf '\033[0;31m[ERR]\033[0m  %s\n' "$*" >&2; }

ERRORS=0
add_err()  { err "$*";   ERRORS=$((ERRORS + 1)); }

# Use Python zipfile if zip(1) is absent (it is on Windows by default).
have_zip() { command -v zip >/dev/null 2>&1; }

file_size() {
    sz=$(wc -c < "$1" 2>/dev/null || echo 0)
    printf '%s' "$sz"
}

# ---------------------------- validation ------------------------------------
validate() {
    log "Validating module contents"

    for f in module.prop system.prop post-fs-data.sh service.sh \
             customize.sh uninstall.sh action.sh hide_root.sh \
             common_func.sh allowlist_manager.sh \
             allowlist.json README.md CHANGELOG.md RELEASE_NOTES.md \
             LICENSE update.json; do
        if [ ! -f "$ROOT_DIR/$f" ]; then add_err "missing: $f"
        else log "  ok $f ($(file_size "$ROOT_DIR/$f") bytes)"
        fi
    done

    for f in META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script; do
        if [ ! -f "$ROOT_DIR/$f" ]; then add_err "missing: $f"; fi
    done

    # Module.prop shape
    grep -q '^id=Rebler$'         "$ROOT_DIR/module.prop"     || add_err "module.prop id != Rebler"
    grep -q '^versionCode='     "$ROOT_DIR/module.prop"     || add_err "module.prop versionCode missing"
    grep -q '^webroot=webroot$' "$ROOT_DIR/module.prop"     || add_err "module.prop webroot missing"

    # All shell scripts: sh -n
    for f in post-fs-data.sh service.sh customize.sh uninstall.sh \
             action.sh hide_root.sh allowlist_manager.sh common_func.sh; do
        if sh -n "$ROOT_DIR/$f" 2>/dev/null; then log "  sh syntax ok: $f"
        else warn "sh syntax check failed for $f"; fi
    done

    # 99.9% only matters where a code path could claim a fake passmark.
    # That means module.prop + customize.sh. README/CHANGELOG may describe
    # the removal explicitly.
    if grep -q '99\.9' "$ROOT_DIR/module.prop" 2>/dev/null; then
        add_err "module.prop still references 99.9 — must not ship a passmark"
    fi
}

validate
if [ "$ERRORS" -gt 0 ]; then err "validation failed: $ERRORS error(s)"; exit 1; fi
ok "validation passed"

[ "$CHECK_ONLY" = true ] && { ok "check-only mode complete"; exit 0; }

# ---------------------------- native build ----------------------------------
build_native() {
    if [ -z "${ANDROID_NDK_HOME:-}" ]; then
        warn "ANDROID_NDK_HOME not set — skipping native Zygisk build"
        warn "  Rebler will still function via its shell-script hide layer."
        return 0
    fi
    # Windows NDKs ship ndk-build.cmd (a cmd wrapper); Unix NDKs ship the
    # ndk-build shell script. Use -f, not -x: on git-bash a .cmd file is
    # runnable (bash hands it to cmd.exe) but is never marked executable.
    ndk_build=""
    if [ -f "$ANDROID_NDK_HOME/ndk-build.cmd" ]; then
        ndk_build="$ANDROID_NDK_HOME/ndk-build.cmd"
    elif [ -f "$ANDROID_NDK_HOME/ndk-build" ]; then
        ndk_build="$ANDROID_NDK_HOME/ndk-build"
    fi
    if [ -z "$ndk_build" ]; then
        warn "ndk-build not found at $ANDROID_NDK_HOME — skipping native build"
        return 0
    fi

    log "Compiling Zygisk native module via NDK ($ndk_build)"
    JNI_DIR="$ROOT_DIR/zygisk_src/jni"
    LOG_DIR="$ROOT_DIR/.build-logs"
    mkdir -p "$LOG_DIR"

    if "$ndk_build" -C "$JNI_DIR" \
            NDK_PROJECT_PATH="$JNI_DIR" \
            APP_BUILD_SCRIPT="$JNI_DIR/Android.mk" \
            NDK_APPLICATION_MK="$JNI_DIR/Application.mk" \
            NDK_OUT="$BUILD_DIR/obj" \
            NDK_LIBS_OUT="$BUILD_DIR/libs" \
            >"$LOG_DIR/ndk.log" 2>&1; then
        ok "native build succeeded"
        return 0
    fi
    warn "native build failed — see $LOG_DIR/ndk.log"
    return 0  # not fatal: shell-script layer still works
}

# ---------------------------- assembly --------------------------------------
rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
ASSEMBLY="$BUILD_DIR/$MODULE_ID"
mkdir -p "$ASSEMBLY"

build_native

# Copy tree
cp "$ROOT_DIR/module.prop" "$ROOT_DIR/system.prop" "$ASSEMBLY/"
cp "$ROOT_DIR/post-fs-data.sh" "$ROOT_DIR/service.sh" "$ASSEMBLY/"
cp "$ROOT_DIR/customize.sh" "$ROOT_DIR/uninstall.sh" "$ASSEMBLY/"
cp "$ROOT_DIR/action.sh" "$ROOT_DIR/hide_root.sh" "$ASSEMBLY/"
cp "$ROOT_DIR/common_func.sh" "$ROOT_DIR/allowlist_manager.sh" "$ASSEMBLY/"
cp "$ROOT_DIR/allowlist.json" "$ASSEMBLY/"
cp "$ROOT_DIR/README.md" "$ROOT_DIR/CHANGELOG.md" "$ROOT_DIR/RELEASE_NOTES.md" "$ASSEMBLY/"
cp "$ROOT_DIR/LICENSE" "$ASSEMBLY/"
cp "$ROOT_DIR/build.sh" "$ASSEMBLY/"
cp -r "$ROOT_DIR/META-INF" "$ASSEMBLY/"
cp -r "$ROOT_DIR/webroot" "$ASSEMBLY/"

# Copy prebuilt native libs if they exist
if [ -d "$BUILD_DIR/libs" ]; then
    mkdir -p "$ASSEMBLY/zygisk"
    for abi in arm64-v8a armeabi-v7a x86 x86_64; do
        if [ -f "$BUILD_DIR/libs/$abi/libRebler.so" ]; then
            cp "$BUILD_DIR/libs/$abi/libRebler.so" "$ASSEMBLY/zygisk/$abi.so"
            ok "  zygisk/$abi.so packaged"
        fi
    done
fi

# Stamp the right version (override only if caller passed a version)
if [ -n "$VERSION" ]; then
    sed -i "s|^version=.*|version=$VERSION|" "$ASSEMBLY/module.prop"
    sed -i "s|^versionCode=.*|versionCode=$VERSION_CODE|" "$ASSEMBLY/module.prop"
fi

# Repackage update.json with the right tag/zipUrl
cat > "$ASSEMBLY/update.json" <<EOF
{
    "version": "$VERSION",
    "versionCode": $VERSION_CODE,
    "zipUrl": "https://github.com/who-lee/Rebler/releases/download/$VERSION/Rebler-$VERSION.zip",
    "changelog": "https://github.com/who-lee/Rebler/releases/tag/$VERSION",
    "tag": "stable"
}
EOF

# Permissions
find "$ASSEMBLY" -type f -name '*.sh'    -exec chmod 0755 {} +
find "$ASSEMBLY" -type f -name 'update-binary' -exec chmod 0755 {} +
find "$ASSEMBLY" -type d -exec chmod 0755 {} +
find "$ASSEMBLY" -type f -exec chmod 0644 {} +

# Build ZIP
ZIP_NAME="${MODULE_NAME}-${VERSION}.zip"
ZIP_OUT="$OUTPUT_DIR/$ZIP_NAME"

if have_zip; then
    (cd "$ASSEMBLY" && zip -qr "$ZIP_OUT" .)
elif command -v python3 >/dev/null 2>&1 && python3 -c "exit(0)" 2>/dev/null; then
    log "ZIP via python3 (zipfile)"
    # On git-bash/MSYS, native Python cannot open /c/...-style paths, so
    # convert with cygpath if it exists (Linux here just keeps the path).
    if command -v cygpath >/dev/null 2>&1; then
        PY_SRC="$(cygpath -w "$ASSEMBLY")" PY_OUT="$(cygpath -w "$ZIP_OUT")"
    else
        PY_SRC="$ASSEMBLY" PY_OUT="$ZIP_OUT"
    fi
    export PY_SRC PY_OUT
    python3 - <<PY
import os, zipfile
src = os.environ['PY_SRC']; out = os.environ['PY_OUT']
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for r, _, files in os.walk(src):
        for f in files:
            p = os.path.join(r, f)
            arc = os.path.relpath(p, src).replace(os.sep, '/')
            z.write(p, arc)
PY
elif command -v node >/dev/null 2>&1 && command -v powershell.exe >/dev/null 2>&1; then
    log "ZIP via node -> PowerShell Compress-Archive"
    node -e "
const {spawnSync}=require('child_process');const path=require('path');
const src='$ASSEMBLY';const out='$ZIP_OUT';
const r=spawnSync('powershell.exe',['-NoProfile','-Command',
  'Compress-Archive -Path \"' + path.join(src,'*') + '\" -DestinationPath \"' + out + '\" -Force'
],{encoding:'utf8'});
if(r.status){process.stderr.write(r.stderr||r.stdout);process.exit(1);}
"
else
    err "no zip, python3, or node+PowerShell — cannot package ZIP"
    err "install python3 or the 'zip' utility and re-run build.sh"
    exit 1
fi

if [ ! -f "$ZIP_OUT" ]; then err "ZIP did not get created"; exit 1; fi
ok "built $ZIP_OUT ($(file_size "$ZIP_OUT") bytes)"

# Mirror to the standard "ready to release" filename
if [ "$OUTPUT_DIR/$ZIP_NAME" != "$OUTPUT_DIR/Rebler-$VERSION.zip" ]; then
    cp "$ZIP_OUT" "$OUTPUT_DIR/Rebler-$VERSION.zip"
fi

# Checksum
if command -v sha256sum >/dev/null; then
    (cd "$OUTPUT_DIR" && sha256sum "$ZIP_NAME" > "$ZIP_NAME.sha256")
elif command -v node >/dev/null 2>&1; then
    if command -v cygpath >/dev/null 2>&1; then
        NSRC="$(cygpath -w "$OUTPUT_DIR/$ZIP_NAME")"
    else
        NSRC="$OUTPUT_DIR/$ZIP_NAME"
    fi
    node -e "
const fs=require('fs'),crypto=require('crypto'),h=crypto.createHash('sha256');
const data=fs.readFileSync('$NSRC');
h.update(data);
fs.writeFileSync('$OUTPUT_DIR/$ZIP_NAME.sha256', h.digest('hex')+'  ${ZIP_NAME}\n');
"
fi

ok "Done. Output: $OUTPUT_DIR/"

# The GitHub workflow uploads output/update.json for each release, so it
# must exist next to the ZIP. Copy the repo-level one (it lives alongside
# module.prop and carries the same tag) into the output dir.
cp "$ROOT_DIR/update.json" "$OUTPUT_DIR/update.json"
ok "update.json staged to output/"

ls -la "$OUTPUT_DIR" 2>/dev/null || true
