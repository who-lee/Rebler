// Rebler - Zygisk native module v1.3.1
// I built this against the official Zygisk API v5 header (vendored as
// zygisk.hpp, unmodified). Per process:
//   - onLoad: stash api/env only. getModuleDir() is NOT valid here — the
//     header restricts it to pre*Specialize, and on some root solutions
//     it returns -1 outside those hooks (config would silently never
//     load, allowlist ignored).
//   - preAppSpecialize: read .flag_zygisk + allowlist.json fresh via
//     getModuleDir(), so WebUI edits are picked up by the next process
//     that starts. Then unshare a private mount namespace for apps not
//     on the allowlist, detach root-manager storage mounts and scrub
//     root-solution env vars. All before the sandbox is enforced.
//   - Child zygotes (webview_zygote etc.) are skipped: isolating them
//     would pollute every child they spawn.
//
// What I deliberately do NOT do:
//   - JNI hooks on ApplicationPackageManager.getInstalledPackages. That
//     needs hookJniNativeMethods over native implementation entries and a
//     device test cycle I do not have here. Deferred, not faked.
//   - Xposed / LSPosed Looper hooks. Same story.

#include <android/log.h>
#include <fcntl.h>
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>
#include <errno.h>

#include <string>
#include <vector>

#include "zygisk.hpp"

#define MOD "Rebler"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  MOD, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  MOD, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, MOD, __VA_ARGS__)

// Storage paths hidden from non-allowlisted apps' mount namespaces.
// /sbin is intentionally NOT in this list — unmounting it kills
// app_process's dynamic linker and crashes the app before it can run.
static const char *const MOUNT_HIDE[] = {
    "/data/adb/modules",
    "/data/adb/ksu",
    "/data/adb/ap",
    "/data/adb/magisk",
    "/data/adb/magisk.db",
    "/data/adb/lspd",
    "/data/adb/riru",
    "/sbin/.magisk",
    "/sbin/magisk",
    "/debug_ramdisk",
    nullptr
};

// Root manager packages. Auto-allowed while deny_root_manager is false so
// the manager app keeps working; denied (namespace-isolated) like any other
// app as soon as the user flips that switch.
static const char *const MANAGER_PKGS[] = {
    "com.topjohnwu.magisk",
    "me.weishu.kernelsu",
    "me.bmax.apatch",
    "org.lsposed.manager",
    "de.robv.android.xposed.installer",
    nullptr
};

// ---------------------------------------------------------------------------
// Config read once per process in onLoad
// ---------------------------------------------------------------------------
struct ReblerState {
    std::vector<std::string> allowlist;
    bool use_zygisk{true};
    bool parse_ok{false};
};
static ReblerState g_state;

// Read a whole file via openat on the module dir. Returns "" on any error.
// Trims surrounding whitespace: the flag files are written as "1\n" by
// `echo 1 > .flag_zygisk`, and the WebUI trims when reading — the native
// side must match, or a "1\n" would silently read as not "1".
static std::string read_file_at(int dirfd, const char *name) {
    if (dirfd < 0) return "";
    int fd = openat(dirfd, name, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return "";
    std::string s;
    s.reserve(4096);
    char buf[4096];
    ssize_t n;
    while ((n = TEMP_FAILURE_RETRY(read(fd, buf, sizeof(buf)))) > 0) {
        // Bounded: a runaway file fails safe (empty) instead of
        // truncating into a half-parsed config.
        if (s.size() + (size_t)n > 65536) { close(fd); return ""; }
        s.append(buf, n);
    }
    close(fd);
    if (n < 0) return "";
    const size_t first = s.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return "";
    return s.substr(first, s.find_last_not_of(" \t\r\n") - first + 1);
}

// Parse allowlist.json. The file is produced by our WebUI/shell tooling as
// compact or pretty JSON; this parser accepts a flexible layout. deny is
// treated as false when the token is absent, so a broken file degrades to
// "managers auto-allowed" (the safe default).
static void read_config_at(int dirfd) {
    g_state.parse_ok = false;
    g_state.allowlist.clear();

    std::string flag = read_file_at(dirfd, ".flag_zygisk");
    if (!flag.empty()) {
        g_state.use_zygisk = (flag == "1");
    }

    std::string body = read_file_at(dirfd, "allowlist.json");
    if (body.empty()) { g_state.parse_ok = true; return; }

    // Extract the "allow" array. Malformed layouts fail closed on the
    // parse flag (the allowlist collected so far still applies).
    size_t a = body.find("\"allow\"");
    if (a == std::string::npos) { g_state.parse_ok = false; return; }
    size_t lb = body.find('[', a);
    if (lb == std::string::npos) { g_state.parse_ok = false; return; }
    size_t rb = body.find(']', lb);
    if (rb == std::string::npos) { g_state.parse_ok = false; return; }

    std::string arr = body.substr(lb + 1, rb - lb - 1);
    size_t i = 0;
    while (i < arr.size()) {
        size_t q1 = arr.find('"', i);
        if (q1 == std::string::npos) break;
        size_t q2 = arr.find('"', q1 + 1);
        if (q2 == std::string::npos) break;
        g_state.allowlist.emplace_back(arr.substr(q1 + 1, q2 - q1 - 1));
        i = q2 + 1;
    }

    // deny_root_manager: strict token parse after the colon. Only an
    // explicit `true` denies; missing field or explicit `false` keeps the
    // safe default (managers auto-allowed). The old code searched the
    // whole file tail for "false", so a package literally named *false*
    // flipped the switch.
    bool deny_mgr = false;
    size_t d = body.find("\"deny_root_manager\"");
    if (d != std::string::npos) {
        size_t c = body.find(':', d);
        if (c != std::string::npos) {
            size_t t = body.find_first_not_of(" \t\r\n", c + 1);
            if (t != std::string::npos) {
                deny_mgr = body.compare(t, 4, "true") == 0;
            }
        }
    }
    if (!deny_mgr) {
        for (int k = 0; MANAGER_PKGS[k]; k++) {
            g_state.allowlist.emplace_back(MANAGER_PKGS[k]);
        }
    }
    g_state.parse_ok = true;
}

static bool package_allowed(const char *name) {
    if (!name) return false;
    for (const auto &s : g_state.allowlist) {
        if (s == name) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Per-process isolation
// ---------------------------------------------------------------------------
static void isolate_app_namespace() {
    // Guard: if unshare fails we are still in the zygote namespace, and
    // running the umount pass there would break every app and Magisk
    // itself. Bail instead of half-applying the hide.
    if (unshare(CLONE_NEWNS) == -1) {
        LOGW("unshare CLONE_NEWNS failed: %s", strerror(errno));
        return;
    }
    // MS_PRIVATE (not SLAVE): a slave namespace still receives mount
    // events from the host, which re-exposes /data/adb if the root
    // solution remounts. Check the return — a failed remount means the
    // detach below would propagate globally.
    if (mount("rootfs", "/", nullptr, MS_PRIVATE | MS_REC, nullptr) != 0) {
        LOGW("mount MS_PRIVATE failed: %s", strerror(errno));
        return;
    }
    for (int i = 0; MOUNT_HIDE[i]; i++) {
        if (umount2(MOUNT_HIDE[i], MNT_DETACH) != 0 && errno != ENOENT) {
            LOGW("umount %s failed: %s", MOUNT_HIDE[i], strerror(errno));
        }
    }
}

static void clean_app_env() {
    static const char *const kill_env[] = {
        "MAGISK_VER", "MAGISK_VER_CODE", "MAGISK_DEBUG",
        "MAGISKTMP", "MAGISK_PATH",
        "KSU",        "KSU_VER",         "KSU_VER_CODE",
        "APATCH",     "APATCH_VER",      "APATCH_VER_CODE",
        "XPOSED",     "XPOSED_BRIDGE",   "LSPOSED",
        nullptr
    };
    for (int i = 0; kill_env[i]; i++) unsetenv(kill_env[i]);
}

// ---------------------------------------------------------------------------
// Module binding
// ---------------------------------------------------------------------------
class ReblerModule : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        this->api_ = api;
        this->env_ = env;
        // Config is read in preAppSpecialize, where getModuleDir() is
        // valid. Nothing to do here besides stashing the handles.
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        // Skip child zygotes (webview_zygote, app_zygote): isolating them
        // would pollute every child they spawn. The pointer is optional —
        // null means a regular app process.
        if (args && args->is_child_zygote && *args->is_child_zygote) {
            api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        // Fresh config read per specialize: valid here per the API docs,
        // and WebUI edits take effect on the next process start.
        int dirfd = api_->getModuleDir();
        if (dirfd >= 0) {
            read_config_at(dirfd);
            close(dirfd);
        } else {
            LOGW("getModuleDir failed, running with defaults");
        }

        const char *pkg = nullptr;
        jboolean release = JNI_FALSE;
        if (args && args->nice_name) {
            pkg = env_->GetStringUTFChars(args->nice_name, nullptr);
            if (env_->ExceptionCheck()) {
                env_->ExceptionClear();
                pkg = nullptr;
            }
            release = (pkg != nullptr) ? JNI_TRUE : JNI_FALSE;
        }
        bool allowed = package_allowed(pkg);

        if (!allowed && pkg != nullptr && g_state.use_zygisk) {
            isolate_app_namespace();
            clean_app_env();
        }
        if (release) {
            env_->ReleaseStringUTFChars(args->nice_name, pkg);
        }
        // We never register hooks that need to survive, so unload the lib
        // after specialization to keep the process clean.
        api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *args) override {
        (void)args;
        api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
    }

private:
    zygisk::Api *api_{nullptr};
    JNIEnv      *env_{nullptr};
};

REGISTER_ZYGISK_MODULE(ReblerModule)