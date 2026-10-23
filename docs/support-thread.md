# Draft: forum support thread (Plugin Support)

Title: **[Plugin] Claude Code for Unraid (beta)**

---

**Claude Code for Unraid** installs Anthropic's Claude Code CLI natively on the Unraid
host: `claude` in any terminal, your login and conversations kept across reboots,
supervised sessions that come back after the array starts, and an enforced safety policy
around an agent that runs as root. It keeps working with the array stopped and Docker
disabled, which is the point: diagnostics and recovery.

**Not affiliated.** This is a community plugin. It is not affiliated with, endorsed by, or
supported by Anthropic or Lime Technology. Claude Code is proprietary Anthropic software; the
plugin downloads it from Anthropic's official servers at install time and verifies it
against Anthropic's signed release manifest. It never redistributes it.

**Status: beta.** The hardware test results for each release are recorded in the
repository (`docs/TESTING.md`). Please read the security section before installing.

## Install

- Community Applications: search "Claude Code", or
- Plugins, Install Plugin: `https://github.com/tabilzad/claude-code-unraid/releases/latest/download/claude-code-unraid.plg`

Requirements: Unraid 7.0.0+, a Claude subscription or API key, about 600 MB free on the
flash drive (the plugin caches the current and the previous binary so that boots never need
the network).

First steps:

```
claude-unraid status
claude-unraid work server
cd /mnt/user/appdata/claude-code-unraid/work/server
claude        # then /login
```

Settings: Settings, User Utilities, Claude Code. Supervised sessions:
`claude-unraid start server`, `claude-unraid attach server` (detach with Ctrl-b d),
`claude-unraid list`, `claude-unraid stop --all`.

## Security, plainly

Claude Code runs as root, like every plugin. The plugin wraps it in a managed policy:

- Manual permission mode (every command and edit prompts); bypass mode disabled; auto mode
  and Remote Control off unless you enable them in the settings.
- A guard hook blocks `mkfs`, `wipefs`, `dd` to a disk, `rm -rf` on `/mnt` or `/boot`,
  `zpool destroy`, SMART state changes, and forces a prompt with a reason for network
  access, container escapes, mounts, cron, service restarts and plugin changes.
- `/boot` is mounted read-only inside every session (the `/proc/<pid>/root` way around it
  is guarded and logged, not closed; the security doc explains).
- One audit line per tool call in the syslog (`claude-code-unraid-audit`), redacted.

**This is not a security boundary.** It reduces accidents and casual prompt injection. The
prompts you approve are your control; the guard matches text and can be bypassed by an
obfuscated command, which the docs list honestly:
<https://github.com/tabilzad/claude-code-unraid/blob/main/docs/SECURITY.md>.

## Storage

Pool mode (array started): login, settings and transcripts under
`<appdata>/claude-code-unraid` (direct pool path when your appdata share lives on one
pool). Fallback mode (array stopped): a temporary config in RAM, for recovery work. An
optional emergency token lets you use Claude Code while the array is down without a browser
login; if you store one, do not export the flash share over SMB. Details:
<https://github.com/tabilzad/claude-code-unraid/blob/main/docs/storage.md>.

## Reporting problems

1. `claude-unraid doctor`
2. `/usr/local/emhttp/plugins/claude-code-unraid/scripts/collect-diagnostics` writes a
   redacted report under `/tmp`; attach it.
3. Open an issue at <https://github.com/tabilzad/claude-code-unraid/issues> or post here
   with the Unraid version, what you did, and what you expected.

## Known limitations (beta)

- x86_64 only (Claude Code's `linux-x64` build).
- Mounts the agent performs inside a session stay inside the session's mount namespace
  (run `mount` from a normal shell).
- Plain `claude` sessions you start by hand are not stopped or restored by the plugin; only
  `claude-unraid start` sessions are.
- The hardware checklist in `docs/TESTING.md` lists what was verified on which Unraid
  versions; reports from other setups (ZFS pools, large arrays) are welcome.
