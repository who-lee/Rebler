/*
 * Rebler WebUI - extracted from index.html so reviewers can read this
 * separately from the markup. All UI behavior lives here.
 *
 * No global dependencies. Uses the WebView-supplied exec API
 * (window.ksu.exec / window.apatch.exec) when available, falls back
 * to read-only mode in a plain browser, and tries Shizuku first if
 * exposed by the host.
 */
(function () {
  'use strict';

  const MOD = 'Rebler';
  const MOD_PATH = '/data/adb/modules/' + MOD;
  const LOG_PATH = '/data/local/tmp/Rebler.log';
  const ALLOWLIST_PATH = MOD_PATH + '/allowlist.json';

  const MANAGER_PKGS = new Set([
    'com.topjohnwu.magisk', 'me.weishu.kernelsu', 'me.bmax.apatch',
    'org.lsposed.manager', 'de.robv.android.xposed.installer'
  ]);

  // ---------- manager / exec detection ----------
  // Order matters: Shizuku may be present alongside a manager browser, so
  // it wins only when nothing root-native injected a bridge.
  function detectManager() {
    if (typeof window.ksu !== 'undefined') return 'kernelsu';
    if (typeof window.apatch !== 'undefined') return 'apatch';
    if (window.shizuku && typeof window.shizuku.exec === 'function') return 'shizuku';
    return 'browser';
  }
  const mgr = detectManager();
  const readOnly = mgr === 'browser';

  // Normalize whatever a bridge returns into { errno, stdout, stderr }.
  //   - Shizuku: Promise of a plain stdout string.
  //   - KernelSU/APatch 1-arg exec: a SYNCHRONOUS plain stdout string
  //     (no object, so a raw `r.errno === 0` check is always false).
  //   - KernelSU/APatch 3-arg exec(cmd, opts, cbName): calls
  //     window[cbName](errno, stdout, stderr) asynchronously.
  //   - Some standalone hosts JSON-encode the whole result.
  function normalizeExecResult(r) {
    if (typeof r === 'string') {
      const t = r.trim();
      if (t.startsWith('{') && t.endsWith('}')) {
        try {
          const j = JSON.parse(t);
          if (j && typeof j === 'object' && 'errno' in j) {
            return {
              errno: j.errno | 0,
              stdout: String(j.stdout || ''),
              stderr: String(j.stderr || '')
            };
          }
        } catch (e) { /* not JSON after all */ }
      }
      return { errno: 0, stdout: r, stderr: '' };
    }
    if (r && typeof r === 'object') {
      return { errno: r.errno | 0, stdout: String(r.stdout || ''), stderr: String(r.stderr || '') };
    }
    return { errno: -1, stdout: '', stderr: String(r || '') };
  }

  // Call the KernelSU/APatch/standalone bridge. Prefers the async
  // callback form (which both KSU and APatch implement), falls back to
  // the legacy sync-string form when the 3-arg overload is missing.
  function callManagerExec(bridge, cmd) {
    return new Promise((resolve, reject) => {
      const cbName = 'exec_cb_' + Date.now() + '_' + Math.floor(Math.random() * 1e9);
      let settled = false;
      const settle = (r) => {
        if (settled) return;
        settled = true;
        try { delete window[cbName]; } catch (e) {}
        resolve(normalizeExecResult(r));
      };
      window[cbName] = (errno, stdout, stderr) =>
        settle({ errno: errno | 0, stdout: stdout || '', stderr: stderr || '' });
      try {
        const r = bridge.exec(cmd, '{}', cbName);
        // Hosts that ignore the callback return synchronously instead.
        if (r !== undefined && r !== null) settle(r);
      } catch (e) {
        // No 3-arg overload present: use the 1-arg sync form.
        try {
          settle(bridge.exec(cmd));
        } catch (e2) {
          settled = true;
          try { delete window[cbName]; } catch (x) {}
          reject(e2);
        }
      }
    });
  }

  async function exec(cmd) {
    const bridge = window.ksu || window.apatch;
    if (bridge) {
      try { return await callManagerExec(bridge, cmd); }
      catch (e) { return { errno: -1, stdout: '', stderr: (e && e.message) || 'exec failed' }; }
    }
    if (window.shizuku && typeof window.shizuku.exec === 'function') {
      try {
        const r = await window.shizuku.exec(cmd, { stdin: '', redirect: false });
        return normalizeExecResult(r);
      } catch (e) { return { errno: -1, stdout: '', stderr: (e && e.message) || 'shizuku failed' }; }
    }
    return { errno: -1, stdout: '', stderr: 'No exec API' };
  }

  // ---------- toast ----------
  function toast(msg, kind) {
    const el = document.createElement('div');
    el.className = 'toast ' + (kind || 'success');
    el.textContent = msg;
    document.getElementById('toasts').appendChild(el);
    setTimeout(() => el.remove(), 3000);
  }

  // ---------- config helpers ----------
  async function readConfig(key, defaultValue) {
    if (readOnly) {
      try {
        const r = await fetch(MOD_PATH + '/.' + key);
        if (r.ok) { const t = await r.text(); return t.trim() || defaultValue || ''; }
      } catch (e) {}
      return defaultValue || '';
    }
    const r = await exec('cat "' + MOD_PATH + '/.' + key + '" 2>/dev/null');
    if (r.errno === 0 && r.stdout) return r.stdout.trim();
    return defaultValue || '';
  }

  async function writeConfig(key, value) {
    const r = await exec(
      'echo ' + JSON.stringify(String(value)) + ' > "' + MOD_PATH + '/.' + key +
      '" && chmod 644 "' + MOD_PATH + '/.' + key + '"'
    );
    return r.errno === 0;
  }

  // ---------- allowlist ----------
  async function loadAllowlist() {
    let raw = '';
    if (readOnly) {
      try {
        const r = await fetch(ALLOWLIST_PATH);
        if (r.ok) raw = await r.text();
      } catch (e) {}
    } else {
      const r = await exec('cat "' + ALLOWLIST_PATH + '" 2>/dev/null');
      if (r.errno === 0) raw = r.stdout;
    }
    if (!raw) raw = '{"allow":[],"deny_root_manager":false,"version":1}';
    let allow = [];
    let deny = false;
    try {
      const j = JSON.parse(raw);
      if (Array.isArray(j.allow)) allow = j.allow.slice();
      if (typeof j.deny_root_manager === 'boolean') deny = j.deny_root_manager;
      else if (j.deny_root_manager === 'true') deny = true;
    } catch (e) {}
    return { allow: allow, deny: deny, raw: raw };
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"]/g, c => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]
    ));
  }

  function renderAllowlist(allowlist) {
    const ul = document.getElementById('allowList');
    const cnt = document.getElementById('allowCount');
    ul.innerHTML = '';
    cnt.textContent = allowlist.allow.length;
    const sorted = allowlist.allow.slice().sort();
    sorted.forEach(pkg => {
      const isMgr = MANAGER_PKGS.has(pkg);
      const tag = isMgr
        ? '<span class="app-tag mgr">Root manager</span>'
        : '<span class="app-tag allow">Allowed</span>';
      const row = document.createElement('div');
      row.className = 'app-item';
      row.innerHTML =
        '<div class="app-pkg">' +
          '<div class="app-pkg-name">' + escapeHtml(pkg.split('.').pop()) + '</div>' +
          '<div class="app-pkg-meta">' + escapeHtml(pkg) + '</div>' +
        '</div>' + tag +
        '<button class="btn secondary" data-rm="' + escapeHtml(pkg) + '" style="width:auto;padding:6px 10px">Remove</button>';
      ul.appendChild(row);
    });
    ul.querySelectorAll('[data-rm]').forEach(b => {
      b.addEventListener('click', () => removeFromAllowlist(b.dataset.rm));
    });
  }

  async function saveAllowlist(list) {
    const deny = document.getElementById('t_hide_mgr')?.checked !== false;
    const payload = JSON.stringify(
      { allow: list, deny_root_manager: deny, version: 1 },
      null, 2
    );
    if (readOnly) { toast('Read-only', 'warn'); return false; }
    const r = await exec(
      'cat > ' + ALLOWLIST_PATH + " <<'__JSON__'\n" + payload + '\n__JSON__\n' +
      'chmod 644 ' + ALLOWLIST_PATH
    );
    return r.errno === 0;
  }

  async function addToAllowlist(raw) {
    const pkg = (raw || '').trim();
    if (!pkg || !/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$/.test(pkg)) {
      toast('Invalid package id', 'warn'); return;
    }
    const cur = await loadAllowlist();
    if (cur.allow.indexOf(pkg) >= 0) { toast('Already on allowlist', 'warn'); return; }
    cur.allow.push(pkg);
    if (await saveAllowlist(cur.allow)) {
      renderAllowlist(cur);
      toast('Allowed ' + pkg, 'success');
    } else {
      toast('Failed to save', 'error');
    }
  }

  async function removeFromAllowlist(pkg) {
    const cur = await loadAllowlist();
    cur.allow = cur.allow.filter(p => p !== pkg);
    if (await saveAllowlist(cur.allow)) {
      renderAllowlist(cur);
      toast('Removed ' + pkg, 'success');
    } else {
      toast('Failed to save', 'error');
    }
  }

  async function clearAllowlist() {
    if (!confirm('Clear the allowlist? Apps become default-deny; managers stay auto-allowed unless "Hide manager apps" is on.')) return;
    await saveAllowlist([]);
    renderAllowlist(await loadAllowlist());
    toast('Allowlist cleared', 'success');
  }

  // ---------- installed apps ----------
  async function refreshInstalled() {
    if (readOnly) { toast('Browser mode — install list unavailable', 'warn'); return; }
    const r = await exec('pm list packages 2>/dev/null | sed "s/^package://"');
    if (r.errno !== 0) { toast('pm failed', 'error'); return; }
    const installed = r.stdout.split('\n').filter(Boolean);
    document.getElementById('installedCount').textContent = installed.length;
    const cur = await loadAllowlist();
    const allowSet = new Set(cur.allow);
    const ul = document.getElementById('installedList');
    ul.innerHTML = '';
    installed.sort().forEach(pkg => {
      const isAllowed = allowSet.has(pkg);
      const isMgr = MANAGER_PKGS.has(pkg);
      let tag;
      if (isMgr)          tag = '<span class="app-tag mgr">Manager</span>';
      else if (isAllowed) tag = '<span class="app-tag allow">allow</span>';
      else                tag = '<span class="app-tag deny">deny</span>';
      const row = document.createElement('div');
      row.className = 'app-item';
      row.innerHTML =
        '<div class="app-pkg">' +
          '<div class="app-pkg-name">' + escapeHtml(pkg.split('.').pop()) + '</div>' +
          '<div class="app-pkg-meta">' + escapeHtml(pkg) + '</div>' +
        '</div>' + tag +
        '<button class="btn secondary" data-toggle="' + escapeHtml(pkg) + '" style="width:auto;padding:6px 10px">' +
          (isAllowed ? 'Remove' : 'Add') +
        '</button>';
      ul.appendChild(row);
    });
    ul.querySelectorAll('[data-toggle]').forEach(b => {
      b.addEventListener('click', () => {
        const pkg = b.dataset.toggle;
        if (allowSet.has(pkg)) removeFromAllowlist(pkg);
        else addToAllowlist(pkg);
        setTimeout(refreshInstalled, 400);
      });
    });
  }

  // ---------- logs ----------
  async function loadLogs() {
    const v = document.getElementById('logViewer');
    if (readOnly) {
      v.textContent = 'Open the WebUI from a root manager for live logs.';
      return;
    }
    const r = await exec('tail -80 ' + LOG_PATH + ' 2>/dev/null || echo "no logs yet"');
    v.innerHTML = (r.stdout || 'No logs')
      .split('\n')
      .map(line => {
        let cls = '';
        if (/\[ERROR\]/.test(line))         cls = 'error';
        else if (/\[WARN\]/.test(line))    cls = 'warn';
        else if (/\[INFO\]/.test(line))    cls = 'info';
        return '<div class="' + cls + '">' + escapeHtml(line) + '</div>';
      })
      .join('');
    v.scrollTop = v.scrollHeight;
  }

  async function clearLogs() {
    if (readOnly) { toast('Read-only', 'warn'); return; }
    const r = await exec('echo > ' + LOG_PATH);
    if (r.errno === 0) { toast('Logs cleared', 'success'); loadLogs(); }
  }

  async function applyHide() {
    if (readOnly) { toast('Read-only', 'warn'); return; }
    toast('Re-applying...', 'success');
    const r = await exec('sh "' + MOD_PATH + '/hide_root.sh"');
    toast(r.errno === 0 ? 'Done' : 'Failed', r.errno === 0 ? 'success' : 'error');
    loadLogs();
  }

  // ---------- toggles ----------
  async function loadToggles() {
    for (const id of ['t_spoof', 't_keystore', 't_zygisk']) {
      if (readOnly) continue;
      const v = await readConfig('flag_' + id.slice(2), '1');
      document.getElementById(id).checked = (v === '1');
    }
    const al = await loadAllowlist();
    document.getElementById('t_hide_mgr').checked = al.deny;
    const sd = await readConfig('state_post_fs_data_done', '0');
    document.getElementById('statusBadge').textContent = (sd === '1') ? 'ready' : 'rebooting';
  }

  async function saveToggles() {
    if (readOnly) { toast('Read-only', 'warn'); return; }
    for (const id of ['t_spoof','t_keystore','t_zygisk']) {
      const v = document.getElementById(id).checked ? '1' : '0';
      await writeConfig('flag_' + id.slice(2), v);
    }
    const cur = await loadAllowlist();
    await saveAllowlist(cur.allow);
    toast('Saved', 'success');
  }

  function updateRootBadge() {
    const el = document.getElementById('rootBadge');
    if (readOnly) {
      el.textContent = 'browser (read-only)';
      document.getElementById('roBanner').classList.add('show');
    } else {
      // The bridge shell does not export KSU/APATCH env vars, so probe the
      // manager's own filesystem instead. Falls back to the injected
      // bridge name when the exec probe ends up useless.
      exec('[ -d /data/adb/ap ] && echo APatch || { [ -d /data/adb/ksu ] && echo KernelSU; } || { [ -d /data/adb/magisk ] && echo Magisk; }').then(r => {
        const o = (r.stdout || '').trim();
        const known = /^(APatch|KernelSU|Magisk)$/.test(o);
        el.textContent = known
          ? o
          : (mgr === 'shizuku' ? 'Shizuku'
             : mgr === 'apatch' ? 'APatch'
             : mgr === 'kernelsu' ? 'KernelSU'
             : 'unknown');
      });
    }
  }

  // ---------- wire-up ----------
  function wire() {
    document.getElementById('btnAdd').addEventListener('click', () =>
      addToAllowlist(document.getElementById('pkgInput').value)
    );
    document.getElementById('pkgInput').addEventListener('keydown', e => {
      if (e.key === 'Enter') document.getElementById('btnAdd').click();
    });
    document.getElementById('btnSaveAllowlist').addEventListener('click', async () => {
      renderAllowlist(await loadAllowlist());
      toast('Reloaded', 'success');
    });
    document.getElementById('btnPurgeAllowlist').addEventListener('click', clearAllowlist);
    document.getElementById('btnRefreshInstalled').addEventListener('click', refreshInstalled);
    document.getElementById('btnRefreshLogs').addEventListener('click', loadLogs);
    document.getElementById('btnClearLogs').addEventListener('click', clearLogs);
    document.getElementById('btnApplyHide').addEventListener('click', applyHide);
    document.getElementById('btnSaveFlags').addEventListener('click', saveToggles);
    document.getElementById('btnReloadPage').addEventListener('click', () => location.reload());

    ['t_spoof', 't_keystore', 't_zygisk', 't_hide_mgr'].forEach(id => {
      document.getElementById(id).addEventListener('change', () => {
        saveToggles();
      });
    });
  }

  async function boot() {
    updateRootBadge();
    await loadToggles();
    renderAllowlist(await loadAllowlist());
    await loadLogs();
    wire();
    setInterval(async () => {
      renderAllowlist(await loadAllowlist());
      if (!readOnly) loadLogs();
    }, 15000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }

  // Test-only hook: expose the pure exec-bridge helpers so the WebUI can be
  // verified headless (Node) without a device. No production behavior hangs
  // off this.
  window.__ReblerBridgeTest = {
    normalizeExecResult: normalizeExecResult,
    callManagerExec: callManagerExec,
    exec: exec
  };
})();
