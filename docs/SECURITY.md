# Security model

Placeholder. Filled in from phase 07 (policy) onwards and completed by the
independent review in phase 11. It will cover: the threat model from
`docs/SPEC.md` section 2, the policy tiers, what the guard cannot catch,
accepted risks, and the flash footprint.

## Policy (phase 07)

Claude Code runs as root on the server. The plugin wraps every session in a managed
policy that Claude Code itself enforces, plus two hooks. None of it is a security
boundary: it reduces the blast radius of mistakes and of casual prompt injection, and it
keeps a human in the loop for the actions that matter. The permission prompts remain
the user's real control.

### What the baseline enforces

`/etc/claude-code/managed-settings.d/99-claude-code-unraid-baseline.json` is rendered
from `policy/99-baseline.json.in` at install and on every boot, and loads last, so its
values win over any user drop-in:

| Setting | Effect |
|---|---|
| `permissions.defaultMode: "default"` | every session starts in Manual mode: commands and edits prompt |
| `permissions.disableBypassPermissionsMode: "disable"` | `--dangerously-skip-permissions` and the bypass mode are refused (Claude Code also refuses them as root) |
| `disableAutoMode: "disable"` (unless `ALLOW_AUTO_MODE="yes"`) | the classifier-driven auto mode is removed from the mode cycle |
| `disableRemoteControl: true` (unless `REMOTE_CONTROL="yes"`) | no session can be driven from claude.ai or the Claude app |
| `permissions.deny` | `mkfs`, `wipefs`, `shred`, `sgdisk --zap`, `zpool destroy/labelclear`, `rm -rf` on `/`, `/mnt`, `/boot` and their children |
| `permissions.allow` | read-only diagnostics only: `smartctl -a/-x/-H/-i/-l <read-only logs>`, `zpool status/list/iostat`, `zfs list/get`, `btrfs filesystem show/usage/df`, `df`, `free`, `uptime`, `dmesg`, `docker ps/stats/images`, `mdcmd status`, `virsh list`, and similar. Not `docker inspect` (exposes container secrets) and not raw `docker logs` |
| `env` | `DISABLE_UPDATES=1`, `DISABLE_AUTOUPDATER=1`: the plugin owns the version |
| `cleanupPeriodDays` | transcript retention (cfg, default 90 days) |
| `hooks` | the guard (PreToolUse), the audit (PostToolUse) and the session registry (SessionStart/SessionEnd), by absolute path, 10 s timeout; the guard runs with `onFailure: "block"` |

Lists in managed drop-ins merge, scalars from the later file win. A user drop-in
(`/boot/config/plugins/claude-code-unraid/policy.d/*.json`, installed as
`50-user-<name>.json`) can therefore add allow or deny rules and settings, but cannot
re-enable bypass mode, auto mode or Remote Control, and cannot remove the hooks.
Every drop-in is validated before it is written, because a managed file that is not a
JSON object stops Claude Code from starting at all; invalid files are skipped with a
notification.

### The guard: two tiers

The guard looks at the whole Bash command string after a light normalisation (empty
quote pairs, backslashes, `//`, `/./`), in any wrapper (`sh -c`, `sudo`, `env`,
`busybox`, absolute paths), because permission rules only see the outermost command.

**Block** (exit 2; Claude is told why and the command never runs): `mkfs*`, `wipefs`,
`shred`, `dd`/`cp`/`tee`/`mv`/redirections to a block device, `sgdisk --zap`,
`zpool destroy|labelclear`, `rm` on `/`, `/mnt`, `/mnt/<anything>`, `/mnt/*/appdata`,
`/boot` (including `..` tricks), and `smartctl` options that change device state
(`-s/--smart`, `-o/--offlineauto`, `-S/--saveauto`, `-X/--abort`, `--set`,
`-l scterc,<timers>`).

**Ask** (a permission prompt with the reason, in every permission mode): downloads piped
into a shell and base64-decoded code; network tools (`curl`, `wget`, `nc`, `ssh`, `scp`,
`sftp`, `smbclient`, remote `rsync`); `docker run` with host-level access; `docker rm|rmi|prune`,
`zfs destroy|rollback`, `btrfs subvolume delete`; `mount`, `umount`, `nsenter`, `unshare`,
`chroot`; service restarts; `crontab`, `at`, `batch`, `emcmd`, writes under `/etc/cron*`;
`plugin install|remove|update`; writes to `/etc/claude-code`, the launcher and helper,
the plugin directory and the installed binary; `smartctl -t` self-tests; and writes to
`/boot` when the flash drive is writable in the session (`--boot-rw`). For the file tools
(`Write`, `Edit`, `MultiEdit`, `NotebookEdit`) the same protected paths prompt.

Unparsable hook input blocks the call (fail closed), and the hook entry carries
`onFailure: "block"` so a crashed guard blocks too.

### What the guard cannot catch

It matches text. Known gaps, kept deliberately rather than pretending otherwise:

- a command assembled from variables (`c=mk; $c"fs" ...`), `eval`, or hex/printf tricks;
- a script written to disk first and executed later (the write is visible in the audit log
  and, when it targets a protected path, prompts);
- interpreters (`python3 -c`, `perl -e`, `php -r`) that open block devices or sockets
  themselves;
- `docker exec <container> ...` beyond the network and `curl | sh` patterns;
- `grep curl file` and similar mentions of a network tool as an argument prompt once
  (a false positive that costs one click; the broad match is what catches
  `docker exec x sh -c "curl ..."`).

The kernel-enforced read-only `/boot` and Manual mode do not depend on the guard. The
independent review in phase 11 maintains the bypass table in this document.

### The audit log

Every tool call produces one syslog line tagged `claude-code-unraid-audit` with the
session id, the working directory, the tool name and, for Bash, the command truncated to
300 characters. Obvious secrets are redacted before logging (`--password=`, `token=`,
`api_key=`, `Authorization:` headers, bearer tokens, AWS key ids, Anthropic/OpenAI/
GitHub/Slack key shapes, `user:password@` in URLs). Tool output is never logged.
