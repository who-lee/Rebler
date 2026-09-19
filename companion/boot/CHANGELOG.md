# Rebler-Boot changelog

## v1.0 (2026-09-19)

- First release: standalone bootloader-signal companion to Rebler.
- Sets the locked verified-boot chain (`ro.boot.flash.locked=1`,
  `ro.boot.verifiedbootstate=green`, `ro.boot.vbmeta.device_state=locked`,
  `ro.secureboot.lockstate=locked`, `sys.oem_unlock_allowed=0`).
- Strips `ro.boot.verifiedbooterror*` markers at post-fs-data and service.
- Bind-mounts a clean `/proc/cmdline` (strips `androidboot.unlocked=1`,
  `androidboot.verifier=disabled`); logs honestly when the kernel refuses.
- Renamed from Rox-Boot to Rebler-Boot alongside the Rebler v1.3 rename.
- Does NOT defeat hardware-backed attestation; bundles no keybox.
