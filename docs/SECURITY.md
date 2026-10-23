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

### Path aliases the guard folds

Two spellings reach a protected place without naming it, so the guard folds them before
matching (found by the review of 2026-10-23):

- `/proc/<pid>/root/...` is another process's root directory. For a host process (pid 1,
  emhttpd, any shell outside the session) that is the host's mount namespace, where the
  flash drive is writable and `/dev/sdX`, `/mnt` and the policy files sit behind a prefix
  the path rules would not see. The guard strips the prefix, runs the block tier on what is
  behind it (`dd ... of=/proc/1/root/dev/sda` and `rm -rf /proc/1/root/mnt/user` are
  blocked) and asks for any other use of the gateway, writes to `/boot` through it
  included. `/proc/<pid>/cwd/` asks as well; reading the links (`readlink`, `ls -l`)
  stays silent.
- `/x/..` is folded lexically (`/etc/foo/../claude-code` is `/etc/claude-code`,
  `/tmp/../mnt/user` is `/mnt/user`), for Bash commands and for the file tools. The rules
  run on the text before and after folding, so a symlink that makes the lexical result
  too optimistic never loosens a rule; `rm -rf` on any `..` path under `/mnt` stays
  blocked.

### What the guard cannot catch

It matches text. Known gaps, kept deliberately rather than pretending otherwise:

- a command assembled from variables (`c=mk; $c"fs" ...`), `eval`, or hex/printf tricks;
- a script written to disk first and executed later (the write is visible in the audit log
  and, when it targets a protected path, prompts);
- interpreters (`python3 -c`, `perl -e`, `php -r`, `node -e`) that open block devices,
  sockets or `/proc/<pid>/root` themselves, or call `setns`;
- `docker exec <container> ...` beyond the network and `curl | sh` patterns;
- `grep curl file` and similar mentions of a network tool as an argument prompt once
  (a false positive that costs one click; the broad match is what catches
  `docker exec x sh -c "curl ..."`).

Manual mode does not depend on the guard: every one of these still draws the ordinary
permission prompt. The read-only `/boot` does not depend on it either, except through the
`/proc/<pid>/root` gateway described next.

### The read-only flash drive and its limit

`claude` remounts `/boot` read-only in a private mount namespace, so a plain write to
`/boot` fails in the kernel, whatever the guard says. The session is still root in the
host's PID namespace, and `/proc/<pid>/root` of any host process is the host's mount
namespace, where `/boot` is writable. The guard asks before that path is used and the
audit log records it, but that is text matching: an interpreter that opens
`/proc/1/root/boot/...` itself, or a `setns` call, gets through with only the ordinary
permission prompt. A PID namespace would close the gateway at the cost of hiding every
host process from the agent (`ps`, `top`, `kill`, `/proc/<pid>`), which this plugin
exists to let it see; it is not done in this version. Treat the read-only flash drive as
what it is: protection against mistakes and casual injection, not against an agent that
is already working against you.

### Accepted risks (independent review, 2026-10-23)

`docs/security-review-2026-10-23.md` is the full report, with a 36-row bypass table. Its
high finding (the `/proc/<pid>/root` gateway) is handled above; its low findings (audit
redaction gaps, unbounded `restore.log` and `sessions.log`, `..` aliasing) are fixed in
this version. Kept as accepted, each inherent to the platform:

- The previous-version fallback trusts the `.sha256` sidecars the plugin wrote on the
  flash drive. Whoever can write the flash drive is root or has physical access already;
  the pinned download is always tried first.
- A `v*` tag on any commit publishes a release. Inherent to tag-triggered releases and
  bounded by push access to the repository.
- In fallback mode the emergency token sits in the session's environment, readable by any
  other root process through `/proc/<pid>/environ`. Every process on Unraid is root; the
  token is opt-in, and exfiltration by the agent itself still draws the network prompt.
- The settings form uses Unraid's `update.php` with a fixed `#command`; the mechanism
  itself can run any script under the web root for an authenticated, CSRF-checked POST.
  That is Unraid's design, not the plugin's.

### The audit log

Every tool call produces one syslog line tagged `claude-code-unraid-audit` with the
session id, the working directory, the tool name and, for Bash, the command truncated to
300 characters. Obvious secrets are redacted before logging (`--password=`, `token=`,
`api_key=`, `Authorization:` headers, bearer tokens, AWS key ids, Anthropic/OpenAI/
GitHub/Slack key shapes, `user:password@` in URLs). Tool output is never logged.
