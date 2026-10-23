# Phase 08: Session registry, supervised sessions, restore

Read `CLAUDE.md`, `docs/SPEC.md` sections 10 and 11, and `docs/SPIKE.md` (hook payload fields, `--resume` behaviour, tmux availability, Remote Control flags). Use plan mode.

## Tasks

1. **Multiplexer:**
   - If SPIKE showed tmux is absent on supported Unraid versions, add a pinned Slackware `tmux` package (and any missing deps such as `libevent`) as `<FILE>` elements with `<SHA256>`, cached on flash and gated with `Min`/`Max` if versions differ. Source it from an official Slackware mirror, and record the source URLs in the plg comments and `NOTICE`. Note: these are small, so the boot-failure rule is satisfied by the flash cache plus SHA256, same as the txz.
   - If tmux is present, use it and add a `doctor` check.
2. **`policy/session-hook`** (PHP), for SessionStart and SessionEnd:
   - Update `<DATA_DIR>/sessions.json` atomically under `flock`.
   - Fields per SPEC section 10.
   - `supervised` is true when the env var `PLUGIN_SUPERVISED=1` is set; the supervisor sets it.
   - `workspace` is derived from the cwd when it's under `<DATA_DIR>/work/`.
   - Keep the file bounded: prune ended entries older than `CLEANUP_DAYS`.
   - In fallback mode, write to the fallback registry instead.
   - Must never block or fail Claude: wrap everything and exit 0, logging errors.
3. **`claude-unraid` session commands:**
   - `start <ws> [--remote-control]`: start a tmux session `PLUGIN-<ws>` in `<DATA_DIR>/work/<ws>` running the launcher with `PLUGIN_SUPERVISED=1`. With `--remote-control`, only if `REMOTE_CONTROL="yes"`, using the flags recorded in SPIKE.
   - `stop <ws>|--all [--timeout N]`: send `/exit`, then SIGTERM, then SIGKILL, bounded by the timeout.
   - `attach <ws>`
   - `list`: workspace, state, session_id prefix, started time.
   - `restore`: SPEC section 10 restore rules. Resume a live-at-shutdown supervised session with `--resume <id>` in its recorded cwd; if the id can't be resumed (per SPIKE behaviour), start a fresh session in that workspace and log it. Respect `MAX_RESTORE`.
4. Wire `stopping` and the `disks_mounted` background restore from phase 06 to these commands.
5. **Unclean shutdown:** a power loss leaves entries without `ended_at`. Treat those the same as live-at-shutdown (that's the point), but never restore an entry whose cwd no longer exists.

## Tests

- **Hook:** start/end payload fixtures captured in SPIKE (redacted); concurrent writes; corrupt `sessions.json` (back it up and start fresh); fallback mode; never non-zero.
- **Restore:** selection logic matrix (supervised or not, ended or not, cwd missing, MAX_RESTORE), plus ordering by most recent.
- **start/stop:** run against a fake `tmux` shim and a fake launcher; check the timeout behaviour.

## Acceptance

- `make check` is green.
- On-box steps for me:
  - start a supervised session, do one action, reboot; it comes back after the array starts and `--resume` shows the history
  - an unsupervised `claude` in a workspace: after a reboot `claude --continue` there works
  - array stop with two supervised sessions finishes quickly
  - Remote Control session appears in the Claude app only when enabled
- PR from `phase/08-sessions`.
