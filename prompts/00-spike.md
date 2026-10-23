# Phase 00: Spike on a real Unraid box

You are verifying the assumptions in `docs/SPEC.md` on a disposable Unraid test server before any plugin code is written. Read `CLAUDE.md` and `docs/SPEC.md` first, especially every item marked **[SPIKE]** and section 15.

## Access

- The test server is reachable as `ssh UNRAID_TEST` (I've set up the key and an ssh config alias). Ask me for the alias if it doesn't work.
- This is a disposable box. Even so, ask before any command that writes outside `/tmp`, `/run` or `/root`. **Never** write to `/boot` or create anything under `/mnt` without asking first.

## Tasks

Collect facts by running commands over SSH. Prefer read-only commands, and keep every experiment self-contained and cleaned up afterwards.

1. **Platform:**
   - `cat /etc/unraid-version`
   - `ldd --version`
   - `uname -a`
   - presence and version of `tmux`, `screen`, `jq`, `gpg`, `zstd`, `php`, `unshare`, `upgradepkg`, `logger`, `sha256sum`, `curl`, `wget`
2. **Mounts:**
   - `findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS,PROPAGATION /boot /mnt /mnt/user` and any pool
   - flash free space
   - whether the flash share is exported over SMB (read `/boot/config/share.cfg` or the flash export setting; report how you determined it)
3. **Binary:**
   - Download the current Claude Code `linux-x64` binary from `https://downloads.claude.ai/claude-code-releases/` into `/tmp/cc-spike/`, following the pattern in Anthropic's `bootstrap.sh`: `<base>/latest`, `<base>/<ver>/manifest.json`, `<base>/<ver>/linux-x64/claude`.
   - Verify the sha256 against the manifest.
   - Record its size and whether it runs: `./claude --version`.
   - Also check whether `<base>/stable` exists and what it returns.
4. **Read-only `/boot` launcher trick:** in `/tmp`, run
   `unshare --mount --propagation unchanged -- sh -c 'mount -o remount,bind,ro /boot && touch /boot/.x; echo rc=$?'`
   and confirm the touch fails inside the namespace while `/boot` stays rw outside. Also confirm a bind mount created under `/tmp` inside the namespace doesn't leak, and report the `/mnt` propagation.
5. **Config dir:** with `CLAUDE_CONFIG_DIR=/tmp/cc-spike/config`, run `./claude --version` and `./claude doctor`. Report which files appear and whether `.claude.json` lands inside the config dir. Don't log in yet.
6. **Hooks:** create `/tmp/cc-spike/config/settings.json` with SessionStart, SessionEnd, PreToolUse and PostToolUse command hooks that append their stdin JSON to `/tmp/cc-spike/hooks.log`. Then **ask me to log in and run a short session.** Interactive login needs me: tell me the exact command to run in an SSH terminal, including a working directory under `/tmp/cc-spike/work`, and what to do (one Bash tool call, then `/exit`). After I confirm, collect the captured payloads, redacting anything token-like.
7. **Persistence of trust:** after I've done step 6, tell me how to check that a second launch in the same cwd doesn't ask for trust again. Record the result.
8. **Session resume:** have me run `claude --resume <id>` in the same cwd and in a different cwd. Record what happens.
9. **Emergency token:** ask me whether to test `claude setup-token` now. If yes, have me run it and then `CLAUDE_CODE_OAUTH_TOKEN=… claude` (I'll paste the token into the environment myself; never ask me to paste it into chat). Record whether an interactive session works with it.
10. **Remote Control:** read `./claude --help` and record the exact flags and subcommands for Remote Control. Don't enable it.
11. **Managed settings:** create `/etc/claude-code/managed-settings.d/99-spike.json` with `{"permissions":{"disableBypassPermissionsMode":"disable"}}`. Confirm `claude --dangerously-skip-permissions` is refused (it's also refused as root, so note which message appears). Then write an *invalid* drop-in and record the exact failure behaviour. **Remove both files afterwards.**

## Output

Write `docs/SPIKE.md` in the repo with:
- one section per task: command(s) run, raw relevant output (trimmed), and the conclusion
- a **SPEC deltas** list: each SPEC statement that turned out wrong or needs a decision, with a proposed fix

Then update `docs/SPEC.md`:
- resolve every **[SPIKE]** marker that the facts settle
- leave unresolved ones marked and list them at the end of SPIKE.md

Clean up everything under `/tmp/cc-spike`, plus `/etc/claude-code` if you created it, and tell me what you removed.

## Acceptance

- `docs/SPIKE.md` exists, and every SPEC section-15 question is answered or explicitly left open with a reason.
- No files remain on the test server outside what I agreed to.
- Commit: `docs: add spike results and resolve spec assumptions`, with a short body if needed and no attribution lines.
