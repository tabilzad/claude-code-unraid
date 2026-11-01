# SPEC: Claude Code for Unraid

Status: draft v2, updated from `docs/SPIKE.md`. The spike was remote (no Unraid box was
reachable), so items marked **[ON-BOX]** are design decisions backed by documentation or
source reading that the hardware checklist in `docs/TESTING.md` must still confirm. The
code treats each of them conservatively: detect at runtime where possible, refuse or
degrade where not.

## 1. Goals and non-goals

**Goals**
- Install a pinned, signature-verified Claude Code CLI natively on the Unraid host, as root, usable from any terminal as `claude`.
- Survive reboots: binary, login, settings, memory, transcripts, per-project trust and MCP config persist.
- Restore sessions: conversations that were live at shutdown come back after `disks_mounted`, and every other conversation stays resumable with `claude --resume` or `claude --continue`.
- Keep working with the array stopped and with Docker disabled. This is the reason a plugin is justified over a container.
- Wrap a root agent in enforced policy: manual permission mode, no bypass mode, a guard hook, an audit trail, and a read-only `/boot` by default (a private mount namespace; `docs/SECURITY.md` states the `/proc/<pid>/root` limit).
- Meet Unraid plugin conventions and CA requirements.

**Non-goals**
- A security boundary. Claude runs as root, and the policy reduces accidents rather than stopping a determined attacker. The docs must say this plainly.
- Running other agents, an embedded web terminal, or a `settings.json` editor.
- Redistributing Claude Code.

## 2. Threat model (summary; full version in docs/SECURITY.md)

| Threat | Mitigation |
|---|---|
| Tampered Claude binary (CDN, MITM, compromised mirror) | CI verifies the GPG-signed manifest against the pinned fingerprint `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`, then pins the sha256 in the `.plg`. The box verifies the sha256 on every boot, before exec |
| Tampered plugin package | `<SHA256>` on every `<FILE>`; releases built only by CI from tags |
| Tampered tmux package | SHA256 pinned in the `.plg` from a package whose Slackware signature CI verified; the box verifies the sha256 before extracting |
| Prompt injection through logs or files the agent reads | Manual mode; guard ask-tier for network, exfiltration, `curl\|sh`, mounts, cron; audit log |
| Agent writes to the flash drive or bricks the boot config | `/boot` remounted read-only in Claude's private mount namespace unless the user explicitly allows it per session; the `/proc/<pid>/root` gateway to the host view is guarded (ask) and logged, not closed (`docs/SECURITY.md`) |
| Agent weakens its own policy | Baseline drop-in restored at every boot and loads last; guard asks before writes to `/etc/claude-code`, the plugin dirs and the launcher; `disableBypassPermissionsMode` |
| Token theft | Tokens never in args, HTML or logs. The emergency token is opt-in, and the user is warned about flash SMB export |
| Remote takeover through a claude.ai account | Remote Control is disabled by managed policy unless the user enables it |
| Hung array stop | Event handlers time out hard; stopping sessions is bounded |
| Boot failure | No boot-critical URL downloads; graceful degradation |

## 3. On-box layout

| Path | Persistence | Contents |
|---|---|---|
| `/boot/config/plugins/PLUGIN.plg` | flash | installed plg |
| `/boot/config/plugins/PLUGIN/` | flash | `PLUGIN.cfg`, `pkg/PLUGIN-<ver>-noarch-1.txz` (Slackware naming, so `upgradepkg` recognises the package; a dev build is `0000.00.00.0_dev`), `pkg/tmux-<pkgver>.txz`, `bin/claude-<cver>` (current plus previous only), `policy.d/*.json` (user drop-ins), `emergency-token` (opt-in) |
| `/usr/local/emhttp/plugins/PLUGIN/` | RAM (from txz) | page, php, `scripts/`, `event/`, `policy/` (baseline), `README.md` |
| `/usr/local/lib/PLUGIN/claude-<cver>` | RAM | binary copied from flash after verification (never exec from FAT) |
| `/usr/local/lib/PLUGIN/bin/tmux` | RAM | `usr/bin/tmux` extracted from the verified Slackware package |
| `/usr/local/bin/claude` | RAM | launcher (section 7) |
| `/usr/local/bin/claude-unraid` | RAM | helper CLI (section 11) |
| `/etc/claude-code/managed-settings.d/` | RAM | `50-user-*.json` user drop-ins, `99-PLUGIN-baseline.json` |
| `/run/PLUGIN/` | RAM | `mode`, `binary.state`, `tmux.state`, lock files, tmux socket, fallback dirs, session supervisor state |
| `/var/log/PLUGIN/` | RAM | bounded install, event and restore logs |
| `<DATA_DIR>/` | pool | `config/` (= `CLAUDE_CONFIG_DIR`), `work/<workspace>/`, `sessions.json` |

`DATA_DIR` defaults to `<appdata>/PLUGIN`. `<appdata>` comes from `DOCKER_APP_CONFIG_PATH` in `/boot/config/docker.cfg`; a direct pool path (`/mnt/<pool>/...`) is preferred over `/mnt/user/...`. The path must already exist, or its parent must be an existing share or pool root. Never create a share.

## 4. Claude Code supply chain

**CI (`scripts/claude-release`)**
1. Resolve the target version for the channel: `GET <base>/stable` (verified: returns a bare version string such as `2.1.308`; `<base>/latest` returns the newest build). Validate against `^[0-9]+\.[0-9]+\.[0-9]+$`.
2. Download `<base>/<ver>/manifest.json` and `manifest.json.sig`.
3. `gpg --verify` against `keys/claude-code.asc` in an isolated `GNUPGHOME`, parsing `--status-fd` for `VALIDSIG` with the pinned fingerprint. The key's fingerprint must equal the pinned constant in the script, and a mismatch fails CI.
4. Read `platforms["linux-x64"].checksum` (64 lowercase hex) and `platforms["linux-x64"].size` (verified present in the manifest).
5. Write `release/claude-code.lock` as `KEY=value` lines: `CLAUDE_VERSION`, `CLAUDE_PLATFORM`, `CLAUDE_SHA256`, `CLAUDE_URL=<base>/<ver>/linux-x64/claude`, `CLAUDE_SIZE`, `MANIFEST_SHA256`, `VERIFIED_AT`.

**Bump workflow:** scheduled daily. If the channel has a newer version, run the steps above and open a PR that updates the lock file. A human merges it, and merging triggers a plugin release.

**On the box:** the `.plg` carries `CLAUDE_VERSION`, `CLAUDE_SHA256`, `CLAUDE_URL` and `CLAUDE_SIZE` as entities (rendered from the lock). The installer:
1. If `bin/claude-<ver>` exists on flash and its sha256 matches, use it.
2. Otherwise check free flash space (refuse below `size x 1.2`), download to a `mktemp` file next to the cache on the flash drive (never under `/run`, which Unraid mounts as a 32 MiB tmpfs), verify the sha256, rename it into place, and prune to current plus previous.
3. Copy it to `/usr/local/lib/PLUGIN/claude-<ver>` through a temp name and `mv`, `chmod 0755`, and re-verify the sha256 of the RAM copy. The target must be a regular file, never a symlink.
4. On any failure, keep the previous verified version if present (degraded mode) and raise an Unraid notification. Never fail the plg install.
5. The binary is served uncompressed (292,232,560 bytes for 2.1.308, about 279 MiB; two cached versions use about 560 MB of flash). `zstd` is not used.

**tmux** follows the same path with its own script (`install-tmux`): entities `TMUX_PKG`, `TMUX_URL`, `TMUX_SHA256`, `TMUX_SIZE`; cache `pkg/<TMUX_PKG>`; extract only `usr/bin/tmux` into `/usr/local/lib/PLUGIN/bin/`. A failure leaves supervised sessions unavailable and is reported by `status` and `doctor`; it never fails the install.

## 5. Lifecycle flows

- **Plugin version:** `YYYY.MM.DD.N`, fixed width because the plugin manager compares versions with `strcmp`: the UTC date of the release tag and a single sequence digit (the tag's position among the tags created that day; a tenth release in one day is an error). Dev builds are `0000.00.00.0-dev`, which sorts below every release. The semantic version lives in the tag (`v0.1.0-beta.1`) and in the `pluginVersion` entity.
- **Install / every boot (plg `Method="install"`):** create dirs; `upgradepkg --install-new --reinstall` the cached txz (this is the only step allowed to fail the install, since nothing works without the package); install the policy baseline (section 9); run the binary install (section 4); run the tmux install; `post-install` writes `/run/PLUGIN/mode=fallback` unless a mode already exists, and logs a summary. No `/mnt` access here, except that `post-install` runs the `disks_mounted` logic once, inline and bounded, when the array is already started (`mdState=STARTED` in `/var/local/emhttp/var.ini`) so that installing while the array runs lands in pool mode.
- **Update:** same as install, plus restart supervised sessions only if the Claude version changed and the user enabled auto-restart.
- **Remove (`Method="remove"`):**
  - stop supervised sessions
  - `removepkg`
  - remove `/usr/local/lib/PLUGIN`, `/usr/local/bin/claude`, `/usr/local/bin/claude-unraid`, the baseline drop-in and every `50-user-*.json` we wrote, `/run/PLUGIN`
  - remove `/boot/config/plugins/PLUGIN/bin` and `pkg`
  - **keep** `PLUGIN.cfg`, `policy.d`, `emergency-token` and `DATA_DIR` (user data). The uninstall message says how to delete them.

## 6. Storage modes

| Mode | When | `CLAUDE_CONFIG_DIR` | Auth | Work dir |
|---|---|---|---|---|
| `fallback` | boot until `disks_mounted`; after `stopping`; DATA_DIR invalid | `/tmp/PLUGIN/fallback-config` (RAM, 0700; not `/run`, a 32 MiB tmpfs) | emergency token if enabled, else interactive login (lost on next mode switch) | `/tmp/PLUGIN/fallback-work` |
| `pool` | after `disks_mounted` with DATA_DIR valid | `<DATA_DIR>/config` | normal OAuth login, persisted | `<DATA_DIR>/work/<name>` |

- The mode lives in `/run/PLUGIN/mode`. Mode switches never happen under a running session: supervised sessions are stopped first, and unsupervised `claude` processes are counted and reported (section 8).
- `CLAUDE_CONFIG_DIR` holds settings, session history, plugins and the login/trust file `.claude.json` (documented; **[ON-BOX]** confirm the file lands under `<DATA_DIR>/config/`).
- Trust is recorded per project path in `.claude.json`, so it persists for a non-home working directory as long as the config dir persists (**[ON-BOX]**).

## 7. Launcher (`/usr/local/bin/claude`)

1. Read `/run/PLUGIN/mode` and the config.
2. Export `CLAUDE_CONFIG_DIR`, `DISABLE_UPDATES=1` and `DISABLE_AUTOUPDATER=1`. In fallback mode with an emergency token, pass `CLAUDE_CODE_OAUTH_TOKEN` through the environment only, never an argument. The variable takes precedence over stored credentials and is used for the whole session (documented; **[ON-BOX]** one interactive check).
3. If the cwd is `/root` or `/`, print a hint about `claude-unraid work <name>`. Don't block.
4. Strip the launcher-only flag `--boot-rw`. Without it, exec through
   `unshare --mount --propagation unchanged -- sh -c 'mount -o remount,bind,ro /boot && exec "$0" "$@"' <real-binary> <args>`.
   If the remount fails, refuse to start and explain why.
5. With `--boot-rw`: only if `ALLOW_BOOT_RW="yes"` in the cfg. Log it with `logger` and print a warning.
6. If no verified binary is installed, explain why (the last install error) and exit 78.

Propagation: the read-only flag is per mount point and never propagates between peers, so the remount stays inside the launcher's namespace whatever the propagation type of `/boot` is. If `/mnt` is a private mount on Unraid (likely, there is no systemd), mounts the agent performs inside its namespace do not reach the host; this is a documented limitation. **[ON-BOX]** confirm `findmnt -o PROPAGATION /boot /mnt` and the trick itself.

## 8. Array lifecycle (event handlers)

All handlers source a common lib, take `flock /run/PLUGIN/event.lock` with a timeout, cap total runtime with `timeout 20`, log one line per action, and always exit 0.

| Event | Action |
|---|---|
| `disks_mounted` | Validate DATA_DIR (never create shares); create `config/` and `work/`; on first run, migrate the fallback config if the user logged in during fallback (ask via notification, don't auto-merge); switch mode to `pool`; start the session restore in the background (section 10) |
| `started` | Log a status summary |
| `stopping` | Stop supervised sessions gracefully (signal the session process, wait at most 10 s total, then SIGKILL); switch mode to `fallback`; warn in syslog listing PIDs of unsupervised `claude` processes whose cwd or open files are under `/mnt` |
| `unmounting_disks` | Backstop: if any supervised session still has files open under DATA_DIR, kill it. Never touch anything we didn't start |
| `stopping_array`, `stopped` | No-op (disks already unmounted) |

## 9. Policy

**Baseline** (`src/.../policy/99-baseline.json.in`, rendered and copied to `/etc/claude-code/managed-settings.d/99-PLUGIN-baseline.json` at install and every boot):

- `permissions.defaultMode: "default"`
- `permissions.disableBypassPermissionsMode: "disable"`
- `disableAutoMode: "disable"` (configurable in the cfg; default disabled)
- `permissions.deny`: catastrophic commands (mirrors the guard block tier)
- `permissions.allow`: read-only diagnostics, scoped exactly. Examples:
  - `smartctl -a|-H|-i|-l *`
  - `zpool status|list|iostat *`
  - `zfs list|get *`
  - `btrfs filesystem show|usage *`
  - `iostat *`
  - `cat /proc/diskstats|/proc/mdstat`
  - `df *`, `free *`, `uptime`
  - `docker ps *`, `docker stats --no-stream *`
  - `dmesg *`
  - `mdcmd status`
  - `virsh list *`

  It does **not** include `docker inspect` (exposes secrets) or raw `docker logs`.
- `hooks.PreToolUse`: guard; `hooks.PostToolUse`: audit; `hooks.SessionStart` / `hooks.SessionEnd`: session registry. Every hook entry has `timeout: 10`; for `SessionEnd` this also raises the 1.5 s default budget.
- `env`: `DISABLE_UPDATES=1`, `DISABLE_AUTOUPDATER=1`
- `disableRemoteControl: true` unless `REMOTE_CONTROL="yes"` in the cfg, in which case the key is omitted from the rendered baseline
- `cleanupPeriodDays` from the cfg (default 90; minimum 1)

Merge semantics (documented): drop-ins load alphabetically after `managed-settings.json`; a later file's scalar replaces an earlier one, lists union, nested objects merge key by key. The `99-` baseline therefore wins on every lock, and `50-user-*` drop-ins can only add rules.

**User drop-ins:** `/boot/config/plugins/PLUGIN/policy.d/*.json`. Each is validated (PHP `json_decode`, top level must be an object) and copied as `50-user-<name>.json`. Invalid files are skipped with a notification. This matters because a managed drop-in that is not a JSON object makes Claude Code refuse to start.

The settings page edits one of them, `policy.d/webgui.json` (installed as `50-user-webgui.json`), through the `policy-save` action of `include/exec.php` (`include/policy.php`): the text must parse as a JSON object, `permissions` must be an object and its `allow`/`ask`/`deny` members lists of strings, keys the baseline locks are reported as ignored (never rejected), the normalised JSON is written to the flash drive only when it differs from the file, an empty text or `{}` removes the file, and `install-policy` runs after every change. Nothing from the request reaches a shell.

**Managed CLAUDE.md:** unless the cfg says `MANAGED_CLAUDE_MD="no"`, `install-policy` copies `policy/CLAUDE.md` to `/etc/claude-code/CLAUDE.md` (mode 0644, only when the content differs) at install and at every boot. Claude Code loads that file before every user and project CLAUDE.md, and `claudeMdExcludes` cannot skip it. It is guidance, never enforcement: the Unraid layout (`/mnt/user`, pools, disks, appdata), the share-creation trap, the read-only flash drive and the RAM root, where state and logs live, and how to behave on a server other people depend on. The template starts with a marker comment (`claude-code-unraid managed CLAUDE.md`); a `/etc/claude-code/CLAUDE.md` without the marker is never replaced or removed, `MANAGED_CLAUDE_MD="no"` removes only a marked file, and `remove` does the same. `status` reports the file as `context file` (`claude_md` in JSON).

**Guard** (`policy/guard`, PHP): two tiers, adapted from `mygrexit/claude-unraid-manager` `claude-guard` (MIT, with attribution in NOTICE).
- **Block (exit 2):**
  - `mkfs*`, `wipefs`, `shred`
  - `dd`/`cp`/`tee`/redirect to a block device
  - `sgdisk --zap*`
  - `zpool destroy|labelclear`
  - `rm` on mount roots (`/`, `/mnt`, `/mnt/*`, `/mnt/*/appdata`, `/boot`)
  - `smartctl` options that change device state: `-s|--smart on|off`, `-o|--offlineauto`, `-S|--saveauto`, `-X|--abort`, `--set=...`, `-l scterc,<r>,<w>` (with values). Self-tests are not blocked (see ask tier).
- **Ask (permissionDecision `ask` with reason):**
  - downloads piped to a shell; base64 decoded to a shell
  - network tools (`curl`, `wget`, `nc`, `ssh`, `scp`, `rsync` remote, `smbclient`)
  - `docker run` with host access
  - `docker rm|rmi|prune`, `zfs destroy|rollback`
  - mount, namespace or chroot commands
  - service restarts, cron/`at`/`emcmd`
  - writes to `/etc/claude-code`, `/usr/local/bin/claude*`, `/usr/local/emhttp/plugins/PLUGIN`, `/boot`
  - `plugin install|remove|update`
  - `smartctl -t` (self-tests are safe but long; ask)
- Normalize before matching (quotes, backslashes, `//`, `/./`). Port the upstream test cases and add Unraid-native ones.
- `Write`/`Edit` tool calls whose absolute `file_path` is under a protected path get the same ask treatment.

**Audit** (`PostToolUse`): `logger -t PLUGIN-audit` with `session_id`, cwd and tool name; for Bash, the command truncated to 300 chars with obvious secrets redacted (`--password=…`, `token=…`, `Authorization:` headers, `AKIA…`). Never log tool output.

## 10. Sessions

- **Workspaces:** `<DATA_DIR>/work/<name>`. Names match `^[a-z0-9][a-z0-9._-]{0,47}$`. Default workspace: `server`.
- **Registry:** `<DATA_DIR>/sessions.json`, written atomically (temp file and rename) under a lock by the `SessionStart` and `SessionEnd` hooks: `{session_id, cwd, workspace, started_at, ended_at, end_reason, supervised, remote_control}`. `SessionEnd` delivers `reason` = `clear | resume | logout | prompt_input_exit | other`; `SessionStart` delivers `source` = `startup | resume | clear | compact | fork`. `clear`/`compact`/`fork` starts update the existing entry's `session_id` chain rather than creating a new supervised entry.
- **Supervised sessions:** started by `claude-unraid start <workspace>` or by the restore step. They run inside the bundled tmux (`/usr/local/lib/PLUGIN/bin/tmux -L PLUGIN`, socket under `/run/PLUGIN/`), session name `PLUGIN-<workspace>`. If tmux is unavailable (fetch failed), `start` refuses with the reason and points at `claude-unraid doctor`.
- **Restore on `disks_mounted` (backgrounded):** for each registry entry that was supervised and had no `ended_at` (meaning it was live at shutdown), and whose cwd exists: start `claude --resume <id>` in its tmux session. If the resume fails (non-zero exit within the grace period), start a fresh session in that workspace and log it. Respect `RESTORE_SESSIONS="yes|no"` (default yes). Never restore more than `MAX_RESTORE` (default 4).
- **Unsupervised sessions** (plain `claude` in a terminal) aren't relaunched. Their transcripts persist, so `claude --continue` or `claude --resume` works in the same cwd. `claude --resume <id>` also works from another directory (searches all projects since v2.1.223).
- **Remote Control:** opt-in per workspace. Requires `REMOTE_CONTROL="yes"` globally plus `--remote-control` on the supervised launch, which runs `claude --remote-control <workspace>` (interactive session with Remote Control; the argument is the session name shown at claude.ai). Server mode (`claude remote-control`) is not used because it cannot answer the trust prompt without a TTY. Remote Control needs a claude.ai login and stores the transcript on Anthropic servers while connected; the docs say so.

## 11. Helper CLI (`claude-unraid`)

| Command | Purpose |
|---|---|
| `status [--json]` | Plugin version, Claude version, verify state, tmux state, mode, DATA_DIR with its apparent size and the transcripts' share of it (`data_dir.bytes`, `data_dir.transcripts_bytes`; `du -sxb` bounded to 10 s, null when unknown), auth present yes/no (never print the token), policy files loaded, managed CLAUDE.md present (`claude_md`), sessions, workspaces |
| `workspaces [--json]` | The directories of the current work dir whose names are workspace names, each with its path, mtime and supervised session state (`name\|path\|mtime\|state` in JSON, like `sessions`); symlinks and other names are skipped |
| `work <name>` | Create a workspace and `cd` hint (prints the path; can't change the parent shell's cwd) |
| `doctor` | Self-checks (PASS/WARN/FAIL lines) followed by `claude doctor` through the launcher; exit 1 when a check failed |
| `start <ws> [--remote-control]` / `stop <ws>\|--all [--timeout N]` / `attach <ws>` / `list` | Supervised sessions |
| `restore` | Run the restore step manually |
| `token set` / `token clear` / `token status` | Emergency token (reads from stdin, never args) |
| `verify` | Re-hash the installed binary against the pinned sha256 |
| `doctor` | Run `claude doctor` through the launcher plus plugin self-checks (flash SMB export from `disks.ini`, DATA_DIR on `/mnt/user` vs pool, free flash space, binary and tmux verify, policy files present) |

## 12. WebGUI

One page: Settings → User Utilities → Claude Code (`ClaudeCode.page`, `Menu="Utilities"`, `Icon="claude-code-unraid.png"` served from the plugin's `images/`; the plg's `launch` attribute is `Settings/ClaudeCode`).
- **Layout:** the page's own sections are plain HTML blocks styled by `styles/claude-code-unraid.css`, packaged with the plugin and loaded with a cache-busting mtime query. Every rule is scoped to `.ccu`; colors are `--ccu-*` tokens that read Unraid's theme variables (`--background-color`, `--mild-background-color`, `--text-color`, `--alt-text-color`, `--table-border-color`, `--border-color`, `--button-text-color`, `--link-text-color`, 7.1 and newer) and fall back to the native 7.0 colors of the theme named in a `data-theme` attribute (black, white, azure, gray, from `$display['theme']` through `ccu_theme()` in `include/ui.php`). Light themes use darker badge colors. The order top to bottom: a header (icon, title, the non-affiliation and root warnings, the diagnostics buttons), notices (the warnings below), six summary cards (Claude Code version with a verified badge, storage mode, login with the emergency-token badge, running sessions with the tmux state, data size with transcripts, plugin version with the policy file count), a "Where things are" key/value block (data directory, config directory, policy files, tmux, emergency token), the Sessions and Workspaces sections, the Permissions editor and the settings form. Buttons are `button.ccu-btn` (quiet outline, inline SVG icon from `ccu_icon()`, `ccu-btn-primary` for Save permissions, `ccu-btn-warn` for Stop all); states are `ccu_badge()` pills with a tone (ok, warn, bad, info, neutral); tables highlight the hovered row and show a centred empty state with the command to run when there is nothing to list. Nothing is fetched from the network. `include/ui.php` holds these helpers and is unit tested.
- **Status panel:** the same data as `claude-unraid status --json`, on the cards and in "Where things are".
- **Settings form:** DATA_DIR, restore on/off, max restore, cleanup days, auto-mode allowed, `/boot` rw allowed, Remote Control allowed, Unraid context (managed CLAUDE.md) on/off. Saved through the standard Unraid `/update.php` with `csrf_token`; `#command` then runs `install-policy` so the baseline is re-rendered. The form keeps Unraid's markdown definition-list layout and inline help (`:name_plug:` blocks) because `/update.php` and the Help toggle depend on it.
- **Actions:** verify binary, run doctor, restore sessions, stop all sessions, show live log (`openTerminal` pattern used by built-in pages), view audit log (the last 200 `claude-code-unraid-audit` lines of `/var/log/syslog`, read from the file's last 4 MiB, control characters stripped; the hook redacted them when it wrote them). Each is posted to `include/exec.php` with an action allowlist; CSRF is enforced globally by `local_prepend.php` (`csrf_token` field or `X-CSRF-Token` header, HTTP 403 otherwise). Output is shown in a scrollable block; doctor and audit do not reload the page.
- **Workspaces table:** name, path, last used (mtime), supervised session state, and an "Open terminal" button that opens Unraid's own web terminal in the directory (`openTerminal('ttyd', name, path)`, the File Manager's mechanism; paths come from the helper, never from the browser).
- **Permissions box:** a textarea holding `policy.d/webgui.json`, saved with the `policy-save` action, the one action that carries request data besides its name (section 9). Errors come back as HTTP 400 with the validation messages; a successful save returns the install-policy output and a note that running sessions keep the old rules.
- **Sessions table:** workspace, state, started, and a copyable `claude-unraid attach <ws>`.
- **Warnings:** flash share exported (`disks.ini` `[flash]` `export` is `e` or `eh`), DATA_DIR on `/mnt/user` FUSE, emergency token present, Remote Control enabled.
- No token entry in the GUI for v1; token management is CLI only.

## 13. Config (`default.cfg`)

```
DATA_DIR=""            # empty = auto (<appdata>/PLUGIN)
CHANNEL="stable"       # informational; the pinned version comes from the plg
RESTORE_SESSIONS="yes"
MAX_RESTORE="4"
CLEANUP_DAYS="90"
ALLOW_AUTO_MODE="no"
ALLOW_BOOT_RW="no"
REMOTE_CONTROL="no"
EVENT_TIMEOUT="20"
MANAGED_CLAUDE_MD="yes"  # install /etc/claude-code/CLAUDE.md with Unraid context (section 9)
```

## 14. Notifications

Use Unraid's `/usr/local/emhttp/webGui/scripts/notify` with `-e "Claude Code"`:
- binary verification failed (alert)
- running a previous version after a failed update (warning)
- tmux unavailable (warning)
- invalid policy drop-in skipped (warning)
- sessions restored or failed (normal or warning)
- flash share exported while an emergency token exists (alert)

## 15. Open questions (status after the remote spike)

1. Unraid version(s) under test; glibc version; does the `linux-x64` binary run? **Partly answered**: glibc 2.40 (7.0) to 2.43 (7.3); the binary is expected to run. **[ON-BOX]** run it.
2. Binary size; is `zstd` present? **Answered**: 292,232,560 bytes; `zstd` present but unused.
3. tmux, screen, jq, gpg present? **Answered**: tmux and screen absent (bundled tmux from Slackware 15.0), jq present on 7.0 but unused, gpg absent.
4. `/boot` and `/mnt` mount propagation; does the unshare-ro launcher work? **[ON-BOX]**; design does not depend on the propagation type.
5. `CLAUDE_CONFIG_DIR` placement of `.claude.json`; trust persistence. **Documented**; **[ON-BOX]** confirm.
6. Hook stdin fields. **Answered** from the hooks reference (SPIKE §6).
7. `CLAUDE_CODE_OAUTH_TOKEN` interactive. **Documented**; **[ON-BOX]** confirm.
8. Remote Control flag syntax; `disableRemoteControl` effect. **Answered** (SPIKE §10).
9. How to resolve the stable version. **Answered**: `GET <base>/stable`.
10. `claude --resume <id>` with a different cwd or after a clean end. **Answered**: works from any directory since v2.1.223; a clean end does not prevent resuming.
