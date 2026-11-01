# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The plugin version shown
in Unraid is `YYYY.MM.DD.N` (release date and sequence number); the semantic version
below is the release tag.

## [Unreleased]

### Changed

- The settings page has a layout of its own instead of the stock definition lists: a
  header with the plugin icon and the diagnostics buttons, summary cards for Claude Code,
  storage mode, login, sessions, data size and plugin version, badges for every state,
  warnings as notices, sections with hover rows and empty states for sessions and
  workspaces, and a proper editor for the Permissions box. The stylesheet follows
  Unraid's theme variables with fallbacks for the 7.0 themes (black, white, azure, gray)
  and ships in the package; nothing is loaded from the network. The actions, settings
  and endpoints are unchanged.

## [0.1.0-beta.4] - 2026-10-31

### Changed

- Claude Code 2.1.309 replaces 2.1.308. The update downloads and verifies the new binary
  (about 280 MB); the previous one stays cached on the flash drive.

### Added

- A Permissions box in the settings page edits the `policy.d/webgui.json` drop-in: allow,
  ask and deny rules are validated as JSON, written to the flash drive only when they
  changed, and applied with `install-policy`. Keys the baseline locks are reported as
  ignored instead of silently overridden.
- The status shows how much the data directory holds and how much of it is transcripts,
  in `claude-unraid status` and on the settings page.
- "Run doctor" on the settings page runs the helper's self-checks and shows the PASS, WARN
  and FAIL lines.
- "View audit log" on the settings page shows the last 200 tool calls from the syslog, as
  the audit hook redacted them.
- A managed `/etc/claude-code/CLAUDE.md` gives every session Unraid context: the share
  layout, the share-creation trap, the read-only flash drive, how to behave on a shared
  server. `MANAGED_CLAUDE_MD="no"` (Settings, "Unraid context for every session") turns it
  off; a file not written by the plugin is never touched.
- `claude-unraid workspaces` lists the workspaces of the current work dir with their
  last-used time and session state, and the settings page shows them with an "Open
  terminal" button that opens Unraid's web terminal in the workspace.

### Fixed

- The daily Claude Code bump workflow failed on every run after the first for the same
  version: the push of the already existing `claude-bump/<version>` branch was rejected.
  It now fetches the branch before pushing. Opening the pull request also needs the
  repository to allow GitHub Actions to create pull requests, which `docs/RELEASING.md`
  now says.

## [0.1.0-beta.3] - 2026-10-31

### Fixed

- `claude-unraid` usage errors ended with their exit code (`... starting with a letter
  or digit 64`). A missing workspace name now says which command needs one, and a bad
  name is quoted back.

## [0.1.0-beta.2] - 2026-10-31

### Fixed

- The Claude Code download failed on real Unraid hardware: the temporary file was
  written under `/run`, which Unraid mounts as a 32 MiB tmpfs. Downloads now go next to
  their cache on the flash drive, which the free-space check already covers, and the
  error message carries the downloader's exit code and last line.
- Fallback mode kept Claude's config, login and transcripts under that same 32 MiB
  `/run`. They now live in `/tmp/claude-code-unraid` (RAM, mode 0700), so a long
  recovery session can no longer fill `/run` for the rest of the system.

## [0.1.0-beta.1] - 2026-10-31

First public beta. Everything below is new.

### Added

- Native install of Claude Code (`linux-x64`), pinned to one version whose sha256 was
  taken from Anthropic's GPG-signed release manifest. The binary is cached on the flash
  drive next to the previous version, verified before every use, and never downloaded
  during boot when the cache is valid. A failed download leaves the plugin installed
  and reports it; a corrupt current binary falls back to the previous verified one.
- `claude` launcher: every session runs in a private mount namespace with `/boot`
  read-only (kernel enforced). `--boot-rw` lifts it for one session when allowed in the
  settings, and is logged.
- Storage modes: pool mode once the array is started (login, settings and transcripts
  under `<appdata>/claude-code-unraid`, a direct pool path when the share lives on one
  pool) and fallback mode in RAM while it is not. The switch happens on
  `disks_mounted`. An optional emergency token on the flash drive makes fallback mode
  usable without a browser login.
- Managed policy baseline, restored on every boot: Manual permission mode, bypass mode
  disabled, auto mode and Remote Control disabled unless enabled in the settings, a
  deny list for catastrophic commands, an allow list of read-only diagnostics, a guard
  hook (blocks `mkfs`, `wipefs`, `dd` to disks, `rm -rf` on `/mnt` and `/boot`,
  `zpool destroy`, SMART state changes; prompts with a reason for network access,
  container host access, mounts, cron, service restarts, plugin changes and edits to
  protected paths), an audit hook (one redacted syslog line per tool call) and a
  session hook that feeds the session registry. User drop-ins under
  `/boot/config/plugins/claude-code-unraid/policy.d/` can tighten the policy.
- Supervised sessions in a bundled tmux (the unmodified Slackware 15.0 package, pinned
  by sha256): `claude-unraid start|attach|list|stop|restore`. Sessions are stopped
  before the array stops, marked for restore, and resumed with `--resume` after the
  array starts. Plain `claude` sessions are left alone.
- `claude-unraid` helper: `status [--json]`, `work`, `token set|clear|status`,
  `verify`, `doctor`, `migrate-login`.
- Settings page under Settings, User Utilities, Claude Code: status, storage mode,
  data directory, policy switches, verify, restore, stop all, install log.
- `scripts/collect-diagnostics`: a redacted report for bug reports.
- Development: Docker dev environment with pinned tools, shell and PHP lint, plg lint,
  escaping lint, 238 bats and 27 PHP tests, an install test with Lime Technology's real
  plugin manager, an emulated-host end-to-end harness (install, read-only `/boot`, pool
  mode, supervised sessions, stop and restore, reboot from cache, update, degraded
  fallback, remove), CI, a daily workflow that proposes Claude Code version bumps as
  pull requests, and a tag-driven release workflow.

### Security

- Independent review before the release (`docs/security-review-2026-10-23.md`). Its
  findings are handled in this version: the guard folds `/proc/<pid>/root` (the host's
  mount namespace, where the read-only flash drive does not apply) and `/x/..` before
  matching, so `dd`, `rm` and `mkfs` through those spellings are still blocked and any
  other use of the gateway asks; the audit log redacts more password forms (`mysql -p`,
  `sshpass -p`, `PGPASSWORD=`, `passphrase:`, a bare `pass X`); `restore.log` and
  `sessions.log` are bounded like `install.log`. `docs/SECURITY.md` states the limit of
  the read-only flash drive plainly and lists the accepted risks.
