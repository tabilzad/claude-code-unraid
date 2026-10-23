# Phase 07: Managed policy, guard hook, audit hook

Read `CLAUDE.md` (invariants 6, 7), `docs/SPEC.md` section 9, and `docs/SPIKE.md` (managed drop-in behaviour, hook payloads, invalid-JSON behaviour).

Study `mygrexit/claude-unraid-manager`'s `claude-guard`, `settings.json` and `tests/run.sh` (MIT). Port the guard's rules and test cases, keep attribution in `NOTICE` and in the file header, and drop the container-specific pieces (the `host` wrapper and `/host/boot`). Use plan mode.

## Tasks

1. **Baseline template** `src/.../policy/99-baseline.json.in`, rendered by `scripts/install-policy` into `/etc/claude-code/managed-settings.d/99-PLUGIN-baseline.json`:
   - the content listed in SPEC section 9
   - `disableRemoteControl` is included or omitted based on the cfg
   - `disableAutoMode` follows `ALLOW_AUTO_MODE`
   - `cleanupPeriodDays` from the cfg
   - the allow list exactly as specified: keep the patterns tight, and note any pattern that could match a write
2. **`scripts/install-policy`:**
   - render the baseline, then validate it with PHP (`json_decode`, `JSON_THROW_ON_ERROR`, top-level object)
   - write it atomically with mode 0644
   - copy each valid user drop-in from `/boot/config/plugins/PLUGIN/policy.d/*.json` as `50-user-<sanitized-name>.json`, skipping and notifying on invalid ones
   - remove stale drop-ins that we created earlier (prefix-matched) but never touch other files in that dir
   - **never write an invalid file**, since Claude Code would refuse to start
   - it runs at install, every boot, and on cfg save from the GUI
3. **Guard** `src/.../policy/guard`:
   - Read the PreToolUse JSON from stdin with PHP.
   - For `Bash`, check the `command`; for `Write`/`Edit`, check the file path against protected paths.
   - **Block tier:** exit 2 with the reason on stderr.
   - **Ask tier:** print a `hookSpecificOutput` JSON with `permissionDecision: "ask"` and a `permissionDecisionReason` that starts with `PLUGIN guard:`.
   - Apply the normalization from the upstream guard.
   - Fail closed: unparsable input exits 2 with a reason.
   - Add Unraid-native rules from SPEC section 9: the smartctl state-changing options as finalized in SPIKE, writes to policy and launcher paths, and `plugin install|remove|update`.
4. **Audit** `src/.../policy/audit`: PostToolUse. Log through `logger -t PLUGIN-audit` per SPEC section 9, with truncation and redaction. Never log tool output. Unit-test the redaction thoroughly.
5. **Registry hook placeholders:** SessionStart and SessionEnd entries pointing at `src/.../policy/session-hook`, a stub that exits 0 until phase 08.
6. Hooks are referenced by absolute paths under `/usr/local/emhttp/plugins/PLUGIN/policy/` and use a timeout of 10 s.

## Tests

- **Guard:** every ported upstream case plus new ones:
  - each block rule with wrapper variants (`sh -c`, absolute paths, quotes, backslashes, `//`)
  - each ask rule
  - false-positive checks (`grep curl file`, `cat /boot/config/go`, `smartctl -a /dev/sdb`, `zpool iostat -v 2`) must pass silently or be allowed
  - unparsable input is blocked
- **install-policy:** valid render; invalid user drop-in skipped and existing good files untouched; stale cleanup; Remote Control on and off; idempotence.
- **Audit:** redaction table tests; truncation; non-Bash tools.

## Acceptance

- `make check` is green; the guard test count is at least the upstream count.
- `docs/SECURITY.md` gets a "Policy" section: what each tier does, and that it's a safety net, not a boundary.
- On-box steps for me:
  - `claude --dangerously-skip-permissions` is refused
  - `smartctl -a` runs without a prompt
  - `smartctl -t short` asks
  - `mkfs` is blocked
  - the audit line appears in syslog
  - an invalid file in `policy.d` is skipped with a notification, and Claude still starts
- PR from `phase/07-policy`.
