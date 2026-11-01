# Testing

## Automated

| Command | What it covers |
|---|---|
| `./scripts/dev-env make check` | lint (shellcheck, shfmt, php -l, plg lint, actionlint, output escaping) and the unit tests: bats for every script and hook with a fake root, PHP tests for the registry, the page endpoints and the validators |
| `./scripts/dev-env --root make e2e-install` | Lime's real plugin manager against the rendered plg: install, reboot, corrupt cache, remove, `<LOCAL>` install |
| `DEV_ENV_DOCKER_ARGS=--privileged ./scripts/dev-env --root make e2e` | the emulated host (`tests/e2e/emulated-host.sh`): the nine scenarios below through the real plugin manager, pkgtools, the real launcher namespace and the real hooks, with a stub Claude binary |

Emulated-host scenarios:

1. fresh install with the array stopped: fallback mode, binary and tmux fetched from the local bucket, policy written, `claude --version` through the read-only wrapper, a write to `/boot` from inside a session fails, `--boot-rw` refused
2. `disks_mounted`: pool mode, data directories created, no share created
3. supervised session: stub Claude in the fake tmux, registry entry, mode switch refused while it runs
4. `stopping`: finished within 15 s, session stopped and flagged for restore, fallback mode
5. reboot: RAM wiped, reinstall from the flash cache with the bucket unreachable, plg not disabled
6. `disks_mounted` again: the session is restored with `--resume <id>`, the flag cleared
7. plugin update: new binary active, previous kept, caches pruned to two, mode kept
8. corrupt cache and no network: previous version used, warning raised, plg still installed
9. remove: RAM side gone, cfg, policy drop-ins and data directory kept

CI runs `make check` on every push and the two end-to-end jobs in parallel; the emulated
host runs in a privileged container (it needs mount namespaces and tmpfs mounts) and is
isolated in its own job for that reason.

The Debian-based dev image stands in for Slackware in the emulation: the Slackware image
has no PHP, which the plugin manager and the hooks need, while the dev image carries
Slackware 15.0's pkgtools, so package handling is identical. What the emulation cannot
cover is below.

## On hardware

Run this on a disposable Unraid box (7.0 or newer, a VM on a trial key is fine) before
the first release and after any change to the launcher, the installers or the event
handlers. Every step says what to run and what to expect. Collect
`scripts/collect-diagnostics` after a failure and attach the file to the issue.

Preparation: SSH as root, a Claude subscription or API key, and a release plg URL (or a
dev build served from your workstation: `make build`, then
`python3 -m http.server 8000` in `dist/` and the URL `http://<ws>:8000/claude-code-unraid.plg`
with `TXZ_URL=http://<ws>:8000/<package>.txz` passed to `make build`).

1. **Fresh install (array stopped).** Settings, Array Operation: stop the array. Plugins,
   Install Plugin, paste the plg URL.
   Expected: the dialog ends with the summary box (`Claude Code <ver> (from download)`,
   `tmux 3.2a`, `storage mode: fallback`); `claude-unraid status` agrees;
   `ls -la /boot/config/plugins/claude-code-unraid/bin` shows `claude-<ver>` and its
   `.sha256`; `claude --version` prints the version; `/boot/config/plugins-error` has
   no `claude-code-unraid.plg`.
2. **Binary verification.** `claude-unraid verify` prints OK. Then
   `echo x >> /usr/local/lib/claude-code-unraid/claude-<ver>` and run it again: FAIL,
   and a notification appears. Reboot or reinstall to repair.
3. **Read-only flash.** In `claude`, ask it to run `touch /boot/probe`. Expected: the
   command fails with "Read-only file system" and `/boot/probe` does not exist
   afterwards. From a normal shell `touch /boot/probe` works (delete it). Then ask it to
   run `echo x > /proc/1/root/boot/probe`: the guard must raise an ask prompt that names
   `/proc/<pid>/root`; decline it (approved, the write would land on the flash drive: the
   gateway is guarded, not closed, see docs/SECURITY.md). Also record
   `findmnt -o TARGET,PROPAGATION /boot /mnt` for docs/SPIKE.md.
4. **`--boot-rw`.** `claude --boot-rw` is refused (exit 80). Enable "Allow writable
   /boot sessions" on the plugin page, run `claude --boot-rw`: a warning is printed, the
   syslog has `session started with --boot-rw`, and `touch /boot/probe` inside the
   session works (delete it). Disable the setting again.
5. **Login in pool mode.** Start the array. Expected within a few seconds: the syslog
   shows `disks_mounted: ... pool mode active` and `claude-unraid status` says `mode:
   pool` with the data directory. `claude-unraid work server`, `cd` there, `claude`,
   `/login`. After login, `ls -la <data dir>/config/` shows `.credentials.json` and
   `.claude.json` (fill in docs/SPIKE.md section 5), and `claude-unraid status` says
   `login: yes`.
6. **Trust persists.** Exit, run `claude` again in the same workspace: no trust prompt.
7. **Diagnostics through Claude.** In a session ask for `smartctl -a /dev/sdX` and
   `zpool iostat -v 2` (or `btrfs filesystem usage`): both run without a permission
   prompt. Ask for `smartctl -t short /dev/sdX`: a prompt with the guard's reason
   appears. Ask for `mkfs.ext4 /dev/sdX`: refused, never runs. Ask for
   `curl https://example.com`: a prompt with "reaches the network". The syslog shows
   one `claude-code-unraid-audit` line per command.
8. **Policy cannot be weakened.** `claude --dangerously-skip-permissions` is refused;
   record the message (docs/SPIKE.md section 11). Put `{` into
   `/boot/config/plugins/claude-code-unraid/policy.d/bad.json`, run
   `/usr/local/emhttp/plugins/claude-code-unraid/scripts/install-policy`: a
   notification says the file was skipped, `claude` still starts. Delete the file.
9. **Supervised session and reboot with autostart on.** `claude-unraid start server`,
   `claude-unraid attach server`, do one action, detach (Ctrl-b d). Reboot. Expected:
   after the array starts, `claude-unraid list` shows `server running`,
   `claude-unraid attach server` shows the conversation history (resumed by id), the
   syslog has `restore: 1 resumed`.
10. **Unsupervised session survives.** In a workspace run plain `claude`, chat once,
    exit. Reboot. `claude --continue` in the same directory restores the conversation.
11. **Array stop with live sessions.** Start two supervised sessions, then stop the
    array from the WebGUI. Expected: the array stops without stalling (less than about
    15 s attributable to the plugin: `grep claude-code-unraid /var/log/syslog` shows
    `stopping: start` and `stopping: done in Ns` with N small); both sessions are gone;
    mode is `fallback`. Start the array: both come back.
12. **Unsupervised session during array stop.** Run plain `claude` in a workspace, stop
    the array. Expected: the syslog warns `unsupervised claude session(s) still using
    /mnt` with the PID; the session is not killed by the plugin.
13. **Reboot with autostart off and the emergency token.** `claude setup-token`, then
    `claude-unraid token set --stdin`. Reboot with array autostart off. Before starting
    the array, `claude` in `/root`: the session authenticates without a browser
    (`fallback mode ... using the emergency token`). `claude-unraid token clear` after
    the test if you do not need it.
14. **Fallback login migration.** With the array stopped and no token, `claude`,
    `/login`. Start the array: a notification asks you to run
    `claude-unraid migrate-login`; run it; `claude-unraid status` shows `login: yes` in
    pool mode.
15. **Remote Control.** With "Allow Remote Control" off, `claude-unraid start x
    --remote-control` is refused (exit 77) and `/remote-control` inside a session is
    refused by policy. Turn it on, apply, `claude-unraid start x --remote-control`: the
    session appears at claude.ai/code. Turn it off again.
16. **WebGUI.** Settings, User Utilities, Claude Code renders in all four themes
    (Settings, Display Settings: white, black, azure, gray): the header, the summary
    cards, the badges and the tables are readable in each, nothing overflows in a narrow
    browser window, and the plugin icon shows in the Settings grid; the cards and "Where things
    are" match `claude-unraid status`; change "Transcript retention" to
    30 and Apply: the progress window shows no error and
    `/etc/claude-code/managed-settings.d/99-claude-code-unraid-baseline.json` now has
    `"cleanupPeriodDays": 30`; set the data directory to `/mnt/user/newshare` and Apply:
    the progress window shows `DATA_DIR not usable` and the cfg is unchanged. Buttons:
    Verify binary (OK), Run doctor (PASS lines, no FAIL), View log (window opens), Audit
    log (the tool calls from step 7, commands redacted). The Workspaces table lists
    the workspace from step 5 and "Open terminal" opens a web terminal whose prompt is in
    that directory. Set "Unraid context for every session" to No and Apply:
    `/etc/claude-code/CLAUDE.md` is gone; back to Yes: it is back, and `/memory` in a new
    session lists it. CSRF:
    `curl -s -o /dev/null -w '%{http_code}\n' -X POST -d action=status http://<server>/plugins/claude-code-unraid/include/exec.php`
    returns 403.
17. **Plugin update.** Install the previous release, then update from Plugins. Expected:
    `claude-unraid status` shows the new plugin version and Claude version,
    `/boot/config/plugins/claude-code-unraid/bin` holds exactly two binaries, mode
    unchanged (pool if the array was started), sessions untouched.
18. **Unraid OS update.** Update Unraid with the plugin installed. After the reboot the
    plugin is listed as installed, `claude --version` works, the policy baseline exists.
19. **Plugin removal.** Plugins, Remove. Expected: the dialog lists what was kept;
    `/usr/local/bin/claude` is gone; `/boot/config/plugins/claude-code-unraid/` holds only
    the cfg, `policy.d` and (if any) the token; the data directory is intact. Reinstall:
    the login is back.
20. **Pool types.** Repeat steps 5, 9 and 11 on a box whose appdata lives on a ZFS pool
    and one on a btrfs/XFS pool if you have both; record the data directory the plugin
    picked (`claude-unraid status`).

Record the run in the table below (one row per release and box), put the captured
values into `docs/SPIKE.md` (sections marked ON-BOX) and mention the result in the
release notes. A release whose row says "not run" has not been verified on Unraid
hardware, whatever the automated suites say.

## Results

| Release | Unraid | Box | Date | Steps passed | Notes |
|---|---|---|---|---|---|
| 0.1.0-beta.1 | | | | not run | automated suites green (`make check`, `e2e-install`, `e2e`); hardware checklist pending |
