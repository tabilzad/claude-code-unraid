# SPIKE: verifying the SPEC assumptions

Status: **remote spike only**. No Unraid test server was reachable from the build
environment, so nothing below was executed on an Unraid box. Every fact here comes
from one of three sources that can be checked without hardware:

- **bucket**: live requests against `https://downloads.claude.ai/claude-code-releases/`
  and `https://downloads.claude.ai/keys/claude-code.asc` (2026-10-22)
- **source**: the `unraid/webgui` repository (`sbin/emhttp_event`,
  `emhttp/plugins/dynamix.plugin.manager/scripts/plugin`, `emhttp/update.php`,
  `emhttp/plugins/dynamix/include/local_prepend.php`) and the Unraid 7.0.0 to 7.3.0
  release notes on docs.unraid.net
- **docs**: the Claude Code documentation at code.claude.com (hooks, settings,
  managed settings, permissions, CLI reference, Remote Control, sessions)

Items marked **ON-BOX** still need the hardware run described in `docs/TESTING.md`.
The design treats each of them conservatively: the code detects the condition at
runtime where it can, and refuses or degrades where it cannot.

## 1. Platform

Source: Unraid release notes, "Base distro" package lists.

| Package | 7.0.0 | 7.1.0 | 7.2.0 | 7.3.0 |
|---|---|---|---|---|
| glibc | 2.40 | 2.41 | 2.42 | 2.43 (7.3.1 note) |
| php | 8.3.8 | 8.3.19 | 8.3.26 | 8.4.21 |
| bash | 5.2.037 | | 5.3.003 | 5.3.009 |
| util-linux (`unshare`, `flock`) | 2.40.2 | 2.41 | 2.41.2 | 2.42 |
| coreutils | 9.5 | 9.7 | 9.8 | 9.11 |
| curl / wget | 8.11.1 / 1.25.0 | | 8.16.0 | 8.20.0 |
| xz | 5.6.3 | 5.8.1 | | |
| zstd | 1.5.6 | 1.5.7 | | |
| jq | 1.6 | | | |
| libevent | 2.1.12 | | | |
| ncurses | 6.5 | 6.5 | 6.5 | 6.6 |
| utempter | 1.2.1 | | | |
| tmux, screen, dtach | **not listed in any release** | | | |
| gnupg | **not listed** | | | |

Conclusions:

- PHP CLI is present on every supported release (8.3 and 8.4), so JSON handling and
  the hooks use PHP. Code must run on PHP 8.3 **and** 8.4 (no deprecated features).
- `jq` is in the 7.0.0 base, but the plugin does not depend on it (CLAUDE.md rule kept).
- `gpg` is absent: signature verification happens in CI only, never on the box.
- `zstd` is present, but the plain Claude binary is used regardless (section 3).
- **tmux is not in the base distro.** See section 12 for the decision.
- glibc 2.40+ is far newer than what the Claude Code `linux-x64` build needs, so the
  binary is expected to run. **ON-BOX**: `/usr/local/lib/PLUGIN/claude-<ver> --version`.
- Current stable at the time of writing is 7.3.3; 7.4.0 is in beta. The minimum version
  stays `7.0.0`.

## 2. Mounts

**ON-BOX**: `findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS,PROPAGATION /boot /mnt /mnt/user`
and the pool roots; flash free space.

Reasoning used for the design (source: kernel semantics, Unraid's init):

- Unraid boots with Slackware-style rc scripts, not systemd. systemd is what makes `/`
  a shared mount; without it mounts are **private by default**. The spike must confirm
  whether Unraid makes `/mnt` shared.
- The read-only flag set by `mount -o remount,bind,ro` is a per-mountpoint flag
  (`MNT_READONLY`). Shared-subtree propagation forwards mount and unmount events, not
  flag changes, so the remount inside the launcher's namespace stays local to that
  namespace **whatever the propagation type of `/boot` is**.
- Consequence if `/mnt` turns out to be private: a mount the agent performs inside its
  namespace (for example mounting a disk under `/mnt/disks/...`) does not propagate to
  the host. This is a documented limitation, not a safety problem; the user can run such
  commands from a normal shell.

**Flash share export** (source: webgui `include/DiskList.php`, `SecuritySMB.page`):
emhttpd writes `/var/local/emhttp/disks.ini`; the `[flash]` section carries
`export="-"` (not exported), `"e"` (exported) or `"eh"` (exported, hidden), plus
`security="public|secure|private"`. `claude-unraid doctor` reads this file. No `/boot`
file needs to be parsed.

## 3. Binary

Source: bucket.

| Request | Result |
|---|---|
| `GET <base>/latest` | `2.1.309` (plain text, no newline) |
| `GET <base>/stable` | `2.1.308` (**exists**; HTTP 200, plain text) |
| `GET <base>/2.1.308/manifest.json` | JSON, 2084 bytes, sha256 `9a01bbf1996be52f13508ef9e47ef3fcf544ac39037ca91b4c87f2b4efc425fb` |
| `GET <base>/2.1.308/manifest.json.sig` | detached GPG signature, 833 bytes |
| `HEAD <base>/2.1.308/linux-x64/claude` | 200, `Content-Length: 292232560`, `application/octet-stream` |

Manifest shape (trimmed):

```json
{
  "version": "2.1.308",
  "manifestSignatureEnforcement": "flag",
  "commit": "320f66eb...",
  "buildDate": "2026-10-22T03:48:37Z",
  "platforms": {
    "linux-x64": {
      "binary": "claude",
      "checksum": "356733f185fa988e6bf3aa9a555269fdd167982a2e2a80d3c8a78037bb92ad58",
      "size": 292232560
    },
    "linux-x64-musl": { "...": "..." }
  },
  "sdkCompat": { "...": "..." }
}
```

GPG verification with an isolated `GNUPGHOME`:

```
fpr: 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
[GNUPG:] GOODSIG BAA929FF1A7ECACE Anthropic Claude Code Release Signing <security@anthropic.com>
[GNUPG:] VALIDSIG 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE 2026-10-22 ... 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
```

Conclusions:

- The pinned fingerprint in the SPEC is correct and the signing key is served at
  `https://downloads.claude.ai/keys/claude-code.asc`.
- The manifest carries `size`, so the lock file records it and the installer scales its
  download timeout and the flash free-space check from it.
- **Flash footprint**: 278.7 MiB per version; current plus previous is about 560 MB.
  The installer refuses to write when free flash space is below `size x 1.2` and the
  docs must warn users with small (4 GB) flash drives.
- Only the glibc `linux-x64` build is used; `linux-x64-musl` is ignored.
- The binary is not compressed in the bucket, so `zstd` is irrelevant.
- **ON-BOX**: the binary runs on Unraid's glibc.

## 4. Read-only `/boot` launcher trick

**ON-BOX**: `unshare --mount --propagation unchanged -- sh -c 'mount -o remount,bind,ro /boot && touch /boot/.x; echo rc=$?'`
must print a "Read-only file system" error and `rc=1`, while `/boot` stays writable
outside. See section 2 for why this is expected to hold. The launcher refuses to start
when the remount fails, so an unexpected result on hardware is loud, not silent.

Verified on Linux (not Unraid) by the emulated host (`tests/e2e/emulated-host.sh`,
scenario 1, privileged container, `/boot` a tmpfs): a write to `/boot` from inside a
session started through the real launcher fails, `/boot` stays writable outside the
session, and `--boot-rw` is refused by default. What remains on-box is Unraid's own
mount layout (vfat on `/boot`, the propagation of `/mnt`).

## 5. Config dir

Source: docs (`env-vars`, `settings`).

- `CLAUDE_CONFIG_DIR` relocates "all settings, session history, and plugins". The
  project-trust and login identity file `.claude.json` lives inside it as well
  (CLAUDE.md platform fact; **ON-BOX** confirmation: the file must appear under
  `<DATA_DIR>/config/` after the first login, not under `/root`).
- Project and local settings cannot set `CLAUDE_CONFIG_DIR` through `env`; the launcher
  exports it in the process environment, which is the documented way.
- Transcripts live at `<config>/projects/<cwd with non-alphanumerics replaced by '-'>/<session-id>.jsonl`.

## 6. Hooks

Source: docs (`hooks` reference). Field names are documented, so the SPEC no longer
depends on captured payloads. **ON-BOX**: capture one real payload per event for the
test fixtures (the fixtures in `tests/` are built from the documented examples until then).

Common fields: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, and for tool
events `permission_mode` (`"default"` for Manual mode, never `"manual"`).

| Event | Extra fields | Notes |
|---|---|---|
| `SessionStart` | `source` = `startup`, `resume`, `clear`, `compact`, `fork`; optional `model`, `agent_type`, `session_title` | exit 2 is not a block for this event |
| `SessionEnd` | `reason` = `clear`, `resume`, `logout`, `prompt_input_exit`, `other` | **default budget 1.5 s**; a per-hook `timeout` raises it, up to 60 s. No decision control |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id` | decision via `hookSpecificOutput.permissionDecision` = `allow`, `deny`, `ask`, `defer`; exit 2 denies with stderr as the reason; precedence deny > defer > ask > allow |
| `PostToolUse` | `tool_input`, `tool_response`, `tool_use_id`, `duration_ms` | no blocking |

For `Write`, `Edit` and `Read`, `tool_input.file_path` is always absolute. Managed hooks
cannot be disabled by a user `disableAllHooks`, and `allowManagedHooksOnly` exists if the
baseline ever wants to restrict hooks to the managed set. A hook's `"ask"` forces a prompt
even in auto mode.

## 7. Persistence of trust

**ON-BOX**. Trust is recorded per project path in `.claude.json`, which persists with the
config dir (section 5). The test: launch twice in the same workspace after a reboot; the
second launch must not show the trust dialog.

## 8. Session resume

Source: docs (`sessions`, `cli-reference`).

- `claude --resume <id>` works from any directory since v2.1.223: it searches the current
  project, its worktrees, then every other project on the machine. Restore still runs in
  the recorded cwd so that the transcript, `CLAUDE.md` and memory of that workspace apply.
- `claude --continue` is per directory (most recent session there).
- A failed resume prints `Failed to resume the conversation` and exits 1. The restore step
  treats a non-zero exit within the first seconds as "cannot resume" and starts a fresh
  session in the workspace, as the SPEC requires.
- Interactive resume restores the permission mode the session was in; the baseline's
  `disableBypassPermissionsMode` still applies.

## 9. Emergency token

Source: docs (`env-vars`, `authentication`).

`CLAUDE_CODE_OAUTH_TOKEN` "takes precedence over keychain-stored credentials" and, unless
the user runs `/login`, "Claude Code uses the token you set for the whole session". That
covers interactive sessions. `claude setup-token` prints the token to the terminal without
saving it and requires a Claude subscription. **ON-BOX**: one interactive session in
fallback mode with the token in the environment.

## 10. Remote Control

Source: docs (`remote-control`, `cli-reference`, `settings-reference`).

- Interactive session with Remote Control: `claude --remote-control [name]` (alias `--rc`).
- Server mode: `claude remote-control --name "X"`; refuses to start when stdin is not a
  TTY and the workspace is untrusted.
- Policy: `disableRemoteControl: true` makes Claude Code refuse `claude remote-control`,
  `--remote-control`, auto-start and the in-session `/remote-control` toggle.
  `remoteControlAtStartup` controls auto-connect; the baseline leaves it unset.
- Remote Control needs a claude.ai login; it is not available with an API key, with
  Zero Data Retention, or with the HIPAA configuration.
- While connected, the transcript is stored on Anthropic servers. The docs must say so.

## 11. Managed settings

Source: docs (`managed-settings`, `settings-reference`, `permission-modes`).

- Linux paths: `/etc/claude-code/managed-settings.json` and
  `/etc/claude-code/managed-settings.d/*.json`, merged in alphabetical order after the
  main file. Hidden files and non-`.json` files are ignored.
- Merge rules between files: single values, later file wins; lists union with duplicates
  removed; nested objects (`env`, `permissions`) merge key by key. So a `99-` baseline
  loads last and its scalars win, while user `50-` drop-ins can only add list entries.
- **A drop-in that is not valid JSON, or whose top level is not an object, makes Claude
  Code refuse to start** and print an error naming the file. This confirms the SPEC rule
  that nothing is written to `/etc/claude-code/` before it is validated.
- Individual invalid entries in an otherwise valid file are dropped with a warning; a few
  keys fail closed (`disableAutoMode` reads as `"disable"` while invalid).
- Keys used by the baseline, as documented: `permissions.defaultMode: "default"`,
  `permissions.disableBypassPermissionsMode: "disable"`, `disableAutoMode: "disable"`
  (also accepted under `permissions`), `disableRemoteControl: true`,
  `cleanupPeriodDays` (whole number, minimum 1; `0` fails validation), `env`, `hooks`.
- As root, `--dangerously-skip-permissions` is refused before any policy is read:
  `--dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons`.
  With the baseline present the mode is also removed from the `Shift+Tab` cycle.
  **ON-BOX**: record which message appears.

## 12. Terminal multiplexer

tmux is absent from Unraid (section 1). Options considered:

1. Install the Slackware `tmux` package system-wide with `upgradepkg`. Rejected: it would
   fight with NerdTools or a user's own package.
2. Extract only `usr/bin/tmux` from the pinned Slackware package into
   `/usr/local/lib/PLUGIN/bin/tmux` and run it with a private socket directory.
   **Chosen.** Nothing outside the plugin's directories changes and removal is trivial.

Package facts (source: `mirrors.slackware.com`, verified 2026-10-22):

| Field | Value |
|---|---|
| URL | `https://mirrors.slackware.com/slackware/slackware64-15.0/slackware64/ap/tmux-3.2a-x86_64-1.txz` |
| Size | 366,896 bytes |
| SHA256 | `c54aaafd013b09ade3ffbdc553b64b9a29835bc717435982defced205a6772b9` |
| Signature | `tmux-3.2a-x86_64-1.txz.asc`, `VALIDSIG EC5649DA401E22ABFA6736EF6A4463C040102233` (Slackware Linux Project `<security@slackware.com>`) |
| Shared libraries | `libutil.so.1`, `libtinfo.so.6` (ncurses), `libevent_core-2.1.so.7` (libevent 2.1.x), `libm`, `libresolv`, `libc` |
| License | ISC (tmux); recorded in `NOTICE` |

All of those libraries are in the Unraid base (libevent 2.1.12, ncurses 6.5+). The 15.0
release tree is frozen, so the URL is stable; `slackware64-current` was rejected because
its packages are replaced in place, which would break the pinned SHA256.

**ON-BOX**: `/usr/local/lib/PLUGIN/bin/tmux -V` prints `tmux 3.2a`.

## 13. Plugin manager behaviour (confirmed from source)

`emhttp/plugins/dynamix.plugin.manager/scripts/plugin`:

- FILE elements are processed in order. For a `Name`d file with `<SHA256>`: an existing
  file whose hash mismatches is deleted and re-downloaded; a matching one is kept.
- Any `Run` command (including INLINE scripts, written to `/tmp/inline<N>-<plg>.sh`) that
  exits non-zero fails the install: `run failed: '<cmd>' returned <rc>`. At boot the plg
  is then moved to `/boot/config/plugins-error`. **Every INLINE script must exit 0.**
- A URL download failure (`wget`, 3 tries, 10 s timeout) fails the install the same way.
- `plugin remove` runs FILE elements with `Method="remove"` and moves the plg to
  `/boot/config/plugins-removed`.
- `Min`/`Max` attributes skip individual files by Unraid version.
- `emhttp_event` runs `/usr/local/emhttp/plugins/*/event/<event>` (a file or every
  executable in a directory of that name) and **blocks until each returns**.
- `update.php` writes `KEY="value"` lines to `/boot/config/plugins/<file>`, with
  `#command` restricted to paths under the document root; CSRF is enforced for every POST
  by `local_prepend.php` (`csrf_token` field or `X-CSRF-Token` header, 403 on failure).

## SPEC deltas

Applied to `docs/SPEC.md` in the same commit:

1. **§4** Stable resolution is `GET <base>/stable`. The manifest's `size` goes into the
   lock file. Binary size and the flash footprint are recorded.
2. **§7** Added the propagation caveat (agent mounts may stay private) and kept the
   "refuse when the remount fails" rule.
3. **§9** Finalized the smartctl state-changing option list: `-s|--smart`,
   `-o|--offlineauto`, `-S|--saveauto`, `-X|--abort`, `--set=`, `-l scterc,<r>,<w>`
   are blocked; `-t|--test` asks.
4. **§10** `SessionEnd` `reason` values recorded; the SessionEnd hook entry carries
   `timeout: 10` because the default budget is 1.5 s. Remote Control flag syntax
   recorded. tmux: bundled from the Slackware 15.0 package, extracted into the plugin's
   own lib dir, run with a private socket, fetched and cached by the plugin's own script
   (same graceful degradation as the Claude binary) rather than a `<FILE URL>` element.
5. **§11/§12** Flash export is read from `/var/local/emhttp/disks.ini`.
6. **§15** Each open question is answered or marked ON-BOX.

## Still open (hardware required)

Tracked as numbered checks in `docs/TESTING.md`:

1. Mount propagation of `/boot` and `/mnt`; the unshare read-only trick.
2. The `linux-x64` binary runs on the installed glibc.
3. `.claude.json` is created inside `CLAUDE_CONFIG_DIR`; trust persists across reboots.
4. Real hook payloads for the four events (fixtures are built from documented examples).
5. `CLAUDE_CODE_OAUTH_TOKEN` in an interactive fallback-mode session.
6. The exact message shown for `--dangerously-skip-permissions` as root with the baseline.
7. The bundled tmux starts on Unraid.

## 13. `/run` is a 32 MiB tmpfs (ON-BOX, confirmed 2026-10-31)

Slackware 15.0 `rc.S` mounts `/run` with `mode=0755,size=32M,nodev,nosuid,noexec`,
and Unraid 7 inherits it. The first beta downloaded the 292 MB binary into a
`mktemp` file under `/run/claude-code-unraid` and failed on the maintainer's box with
"download failed", while the 366 KB tmux package succeeded. Downloads now go next to
the flash cache and the fallback config lives under `/tmp/claude-code-unraid`.
