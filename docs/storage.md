# Storage and persistence

Unraid runs from RAM. Only the flash drive (`/boot`) and the array or pools under
`/mnt` survive a reboot, and `/mnt` is only there while the array is started. The
plugin therefore has two storage modes and switches between them as the array starts
and stops.

## Where things live

| What | Where | Survives a reboot |
|---|---|---|
| Claude Code binary (cached) | `/boot/config/plugins/claude-code-unraid/bin/` (current and previous version, about 280 MB each) | yes |
| Plugin settings | `/boot/config/plugins/claude-code-unraid/claude-code-unraid.cfg` | yes |
| Your policy drop-ins | `/boot/config/plugins/claude-code-unraid/policy.d/` | yes |
| Emergency token (optional) | `/boot/config/plugins/claude-code-unraid/emergency-token` | yes |
| Login, settings, memory, transcripts, project trust, MCP config | `<data dir>/config/` (this is `CLAUDE_CONFIG_DIR`) | yes, once the array is started |
| Workspaces (`claude-unraid work <name>`) | `<data dir>/work/<name>/` | yes |
| Session registry | `<data dir>/sessions.json` | yes |
| Runtime state, locks, fallback config | `/run/claude-code-unraid/` | no |
| Plugin logs | `/var/log/claude-code-unraid/` | no |

The data directory defaults to `<appdata>/claude-code-unraid`, where `<appdata>` is the
default appdata path from Settings > Docker (usually `/mnt/user/appdata`). When that
share is set to live on a single pool, the plugin uses the direct pool path (for example
`/mnt/cache/appdata/claude-code-unraid`) instead of the `/mnt/user` FUSE path, which is
faster and keeps the mover out of the way. You can set any path under an existing share
or pool directory in the plugin settings. The plugin never creates a share: the parent of
the data directory must already exist.

Transcripts can contain anything the agent read or wrote on your server. Keep the data
directory on a share that only you can access.

## Pool mode

Active after the array has started and the data directory is usable. Claude Code uses
`<data dir>/config` as its configuration directory, so logging in with `/login` once is
enough: the login, trust decisions for your workspaces and all conversations persist
across reboots.

## Fallback mode

Active from boot until the array starts, after the array stops, and whenever the data
directory is not usable. Claude Code uses a configuration directory in RAM
(`/tmp/claude-code-unraid/fallback-config`). This is what lets you use Claude Code to
diagnose a server whose array will not start, which a Docker container could not do.

Everything you do in fallback mode is lost when the mode switches or the server reboots:
the login, the conversation, any files you create under the fallback workspace. If you
logged in during fallback mode and want to keep it, the plugin tells you how when the
array starts; it never merges the two configurations on its own.

## The emergency token

Logging in needs a browser round trip. To skip it while the array is down, you can store
a long-lived token on the flash drive:

```sh
claude setup-token          # prints a token; copy it
claude-unraid token set --stdin   # paste it; the input is hidden
```

or pipe it in from a password manager: `my-pw-manager show claude-token | claude-unraid token set`.

The launcher passes the token to Claude Code through the environment
(`CLAUDE_CODE_OAUTH_TOKEN`), only in fallback mode, and never on a command line.
`claude-unraid token status` and `token clear` manage it; nothing ever prints it.

Trade-off: the token grants access to your Claude account. The flash drive is a FAT
filesystem (no file permissions) and can be exported over SMB as the `flash` share. If
it is exported, anyone who can read that share can read the token. `claude-unraid doctor`
and the plugin page warn about this; the fix is Main > Boot Device > Flash > SMB
Security Settings > Export: No. If you do not need Claude Code while the array is down,
do not store a token.

## What a reboot looks like

1. Boot: the plugin reinstalls from the flash cache (no network needed), restores the
   managed policy, and enters fallback mode. `claude` works, in RAM.
2. The array starts: `disks_mounted` fires, the data directory is validated, the mode
   switches to pool, and supervised sessions that were live at shutdown are resumed in
   their workspaces.
3. The array stops: supervised sessions are stopped first (bounded by 10 s), then the
   mode switches back to fallback. Plain `claude` sessions started by hand in a terminal
   are not stopped, but they are reported in the syslog with their PIDs because their
   working directory is about to disappear.

## `/boot` is read-only for the agent

`claude` runs Claude Code in a private mount namespace where `/boot` is remounted
read-only. The agent can read the flash drive (plugin configs, `go` file, `syslinux.cfg`),
and a plain write to it fails in the kernel. One way around exists, because the session
is still root in the host's PID namespace: `/proc/<pid>/root/boot` of a host process is
the writable host view. The guard asks before that path is used and logs it, but it
matches text (`docs/SECURITY.md`, "The read-only flash drive and its limit"). To allow
writes for one session:

```sh
claude --boot-rw
```

This works only when "Allow writable /boot sessions" is enabled in the plugin settings,
prints a warning and is logged. If the read-only remount fails for any reason, `claude`
refuses to start instead of silently running with a writable flash drive.

Known limitation: mounts the agent performs inside its session (for example mounting a
disk under `/mnt/disks`) stay inside the session's namespace. Run such commands from a
normal shell.
