# Phase 05: Launcher, storage modes, config, emergency token

Read `CLAUDE.md`, `docs/SPEC.md` sections 6, 7, 11 and 13, and `docs/SPIKE.md` (mount propagation, `CLAUDE_CONFIG_DIR`, oauth token, trust). Use plan mode.

## Tasks

1. **`src/usr/local/emhttp/plugins/PLUGIN/default.cfg`**, exactly as in SPEC section 13. Add `cfg_get` defaults handling: the user cfg on flash overrides the defaults.
2. **`scripts/data-dir`:** resolves DATA_DIR per SPEC section 3.
   - Read `DOCKER_APP_CONFIG_PATH` from `docker.cfg` without sourcing it.
   - Prefer a direct pool path when `/mnt/user/<share>` maps to a single pool (only when determinable; otherwise keep the configured path).
   - Validate per CLAUDE.md invariant 2 and print the reason when invalid.
   - **Never `mkdir` the share root itself.** Only create `PLUGIN/` inside an existing share or pool path.
3. **`scripts/mode`:**
   - `get`
   - `set fallback|pool`, refused if supervised sessions are running, unless `--force` is passed by the event handlers after they've stopped sessions
   - `config-dir`, which prints the active `CLAUDE_CONFIG_DIR`
   - Fallback dirs are created 0700 under `/run/PLUGIN/`.
4. **`src/usr/local/bin/claude`**, the launcher, implementing SPEC section 7 exactly:
   - Exports: `CLAUDE_CONFIG_DIR`, `DISABLE_UPDATES=1`, `DISABLE_AUTOUPDATER=1`.
   - Emergency token: when mode is fallback and the token file exists, read it into `CLAUDE_CODE_OAUTH_TOKEN` in the launcher's environment only. Never pass it as an argument, and never export it in pool mode.
   - Exec the binary from `binary.state` inside the unshare/ro-`/boot` wrapper, using the exact form that SPIKE.md proved works.
   - `--boot-rw` handling per the cfg.
   - Exit 78 with a clear message when no verified binary is available.
   - Exit codes and messages are documented in the script header.
5. **`src/usr/local/bin/claude-unraid`**, the helper:
   - implement `status`, `work`, `token set|clear|status`, `verify` and `doctor` now
   - session commands are stubs that print "available after phase 08"
   - `token set` reads stdin with a TTY check, so it refuses when stdin is a terminal without `--stdin`, and writes atomically to flash
   - `doctor` checks: flash SMB export (method from SPIKE.md), DATA_DIR on `/mnt/user` FUSE versus a pool, flash free space, binary verify, policy files present, and `claude doctor` through the launcher
6. **Docs:** a "Storage and persistence" section in `docs/` for users, explaining both modes and the emergency-token trade-off. Plain language, no marketing.

## Tests

bats with the fake root:
- data-dir resolution matrix: cfg set or empty; docker.cfg present or absent; `/mnt/user` vs pool; non-existent share must not be created
- launcher env correctness per mode
- the token never appears in `ps`-visible args: assert through a fake binary that dumps its argv and env to a file
- `--boot-rw` refused or allowed per the cfg
- exit 78 path
- `token set` from a pipe, and refused from a TTY

The unshare wrapper itself can't run in CI without privileges. Test the command construction, and mark the real behaviour as on-box only.

## Acceptance

- `make check` is green.
- Give me the on-box test steps:
  - fallback mode before the array starts (I'll test by booting with array autostart off)
  - a `touch /boot/x` attempt from inside `claude` that must fail
  - `--boot-rw` when allowed
  - `claude-unraid doctor`
- PR from `phase/05-launcher-storage`.
