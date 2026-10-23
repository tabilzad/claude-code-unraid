# Phase 04: On-box install, update and remove logic; binary cache

Read `CLAUDE.md`, `docs/SPEC.md` sections 3, 4, 5 and 14, and `docs/SPIKE.md` (binary size, zstd). Use plan mode.

## Tasks

Implement these under `src/usr/local/emhttp/plugins/PLUGIN/scripts/`. All of them honour the `ROOT` prefix for tests.

1. **`lib.sh`**, the common library:
   - `log` (to `/var/log/PLUGIN/install.log` and `logger -t PLUGIN`)
   - `notify` (wraps Unraid's notify script; no-op in tests)
   - `cfg_get` (safe `KEY="value"` parser, never `source`)
   - `with_lock`, `atomic_write`, `sha256_eq`
   - `run_with_timeout`
2. **`install-binary`**, implementing SPEC section 4 "On the box" exactly:
   - Inputs come from the env vars `CLAUDE_VERSION`, `CLAUDE_SHA256` and `CLAUDE_URL`. Validate each with strict regexes, and require the URL to be `https://downloads.claude.ai/claude-code-releases/<ver>/linux-x64/claude`.
   - Flash cache is `/boot/config/plugins/PLUGIN/bin/claude-<ver>`, keeping current plus previous only.
   - Download to `/run/PLUGIN/dl.XXXX` (mktemp) with curl: `--fail --proto '=https' --tlsv1.2`, a `--max-time` scaled to the size, and 3 retries. Fall back to wget with an equivalent setup only if curl is missing.
   - Verify the sha256 **before** moving to flash, and again after copying to `/usr/local/lib/PLUGIN/claude-<ver>`. Write the RAM copy to a temp name and `mv` it, so the copy is never half-written and the path is checked to be a regular file, not a symlink.
   - Write `/run/PLUGIN/binary.state` (`version`, `sha256`, `source=cache|download|previous`, `error`).
   - On failure: fall back to the previous verified version (notify, warning); if there's none, record the error (notify, alert). **Always exit 0** so the plg install continues (invariant 3). Exit non-zero only on programming errors, and the plg must tolerate that too.
   - Check free space on flash before writing, and refuse below `size × 1.2` with a clear message.
3. **`install-policy`:** a stub in this phase (phase 07 fills it in). It must exist so the plg calls it.
4. **`remove`:** SPEC section 5's remove flow. Must be safe if partially installed. Print exactly what was kept and how to delete it.
5. **`post-install`:** create `/run/PLUGIN`, set `mode=fallback` unless it already exists (so a plugin *update* while the array runs keeps the current mode), and print the summary that appears in the plugin install dialog.

## Tests (bats, fake root, no network)

Use a local `file://` or `python -m http.server` fixture served inside the test, and an override env var for the URL prefix accepted only in test mode. Cover:
- fresh install: download, verify, cache, RAM copy
- reinstall with a valid cache: no download
- corrupt cache: re-download
- download fails with a previous version present: degraded, exit 0
- download fails with no previous version: error state, exit 0
- wrong sha256: rejected; nothing written to flash
- symlink planted at the RAM target: refused
- low flash space: refused
- prune keeps exactly two versions
- remove after a partial install

## Acceptance

- `make check` is green, and the new tests are listed.
- Tell me the exact commands to test on the Unraid test box: install the dev-built plg from a local HTTP server on my workstation, check `/run/PLUGIN/binary.state` and run `/usr/local/lib/PLUGIN/claude-<ver> --version` directly (the `claude` launcher and `claude-unraid` arrive in phase 05), reboot, check again. Include an offline reboot (unplug the network) to prove the flash cache path. I'll run them and report back. Don't claim on-box success yourself.
- PR from `phase/04-install-logic`.
