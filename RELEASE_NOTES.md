# Rebler v1.3.1

Fix release for everything the v1.3 audit found: installer now passes
the ZIP path correctly and detects KernelSU/APatch module dirs;
ZIP entries carry real Unix permissions; `update.json` is stamped from
the tag; the Zygisk layer reads config where the API allows, checks
every mount call, skips child zygotes, and parses `deny_root_manager`
strictly; the WebUI preserves the manager toggle, never hangs on a dead
bridge, and disables controls in read-only mode. See CHANGELOG for the
full list.

---

# Rebler v1.3

Rebler is the root-hider I rebuilt after the v1.4 of the previous project got roasted on Telegram. v1.3 renames the module from Rox2 to Rebler. The full story is in the README; this file is the short list of what to do.

## Install

1. Download `Rebler-v1.3.1.zip` below.
2. Install via Magisk, KernelSU, or APatch.
3. Reboot.
4. Open the WebUI:
   - **Magisk**: tap the play button.
   - **KernelSU**: tap the Rebler module card.
   - **APatch**: tap the Rebler module card.

## Companion: Rebler-Boot v1.0

`Rebler-Boot` (`companion/boot`, id `ReblBoot`) goes one level deeper on
bootloader-state signals: same locked verified-boot chain, strips
`ro.boot.verifiedbooterror*` markers, and bind-mounts a clean
`/proc/cmdline`. It is optional and standalone — install it the same way
via your manager's Local Install menu, then reboot. It cannot defeat
hardware-backed attestation; for STRONG integrity use TrickyStore with
your own keybox.

## First-run

The WebUI opens with an empty allowlist. **Every app is hidden from root by default.** The root managers themselves (Magisk, KernelSU, APatch) are auto-allowed so they keep working.

Add packages to the allowlist if you want them to see root. The list lives at `/data/adb/modules/Rebler/allowlist.json` on the device. You can edit it by hand or through the WebUI.

## What I did not include (and why)

I deliberately did not ship:

- **Fake Play Integrity attestation chains.** If you need **STRONG** Play Integrity, get a keybox from your own device via TrickyStore and point Rebler at it. I am not your source for stolen Google intermediate CAs.
- **A "passmark" percentage.** I cannot measure this; I will not invent it. The README has the actual list of what Rebler does.
- **Placeholder bootloader props.** v1.1 had guessed values for `vbmeta.size`, `vbmeta.digest`, `hardware.platform` and the like; v1.2 deletes them because a shared fake value is itself a fingerprint.

The module passes **Play Integrity BASIC** on the devices I test and makes a solid attempt at **DEVICE** (clean verified-boot chain + clean props). Banking/streaming apps that only require DEVICE typically accept it. If your bank app demands STRONG, see above — that requires real key attestation from your own hardware, not my module.

## After install

If you want to re-apply the prop spoof without rebooting:

```bash
adb shell sh /data/adb/modules/Rebler/hide_root.sh
```

If the WebUI behaves oddly, check the module log first — it tells you which
flags are on and what the allowlist file looks like:

```bash
adb shell tail -50 /data/local/tmp/Rebler.log
adb shell cat /data/adb/modules/Rebler/allowlist.json
```

Then re-open the WebUI (KernelSU/APatch: tap the module card; Magisk: tap the
play button). If it still misbehaves, toggle the switch for the affected
feature (Spoof / Keystore / Zygisk) and re-apply.

## Community

Telegram: [@lestramk](https://t.me/lestramk). I am the only person maintaining this, so replies take time. Be specific when you file an issue — device model, root manager and version, target app, log line.

— lee-muriithi-kingori
