# Independent security review — 2026-10-23

Reviewer: independent adversarial pass (did not write the code). Scope: the whole
`claude-code-unraid` repository, looking for ways the plugin makes an Unraid server
**less** safe than not having it, beyond the accepted risk that a root agent can do
root things once the user approves a prompt.

Method: read `CLAUDE.md`, `docs/SPEC.md`, `docs/SECURITY.md`, `docs/SPIKE.md`, then the
whole tree. The guard, audit hook and a namespace-escape hypothesis were tested by
running them in the pinned dev image (`./scripts/dev-env`, PHP 8.3.36) and, for the
mount-namespace proof, in a `--privileged` dev container. Every "actual" result below is
from a command that was run, not inferred.

## Summary of findings

| # | Severity | Area | File (key line) | One line |
|---|---|---|---|---|
| 1 | **HIGH** | Launcher / guard | `src/usr/local/bin/claude:115`, `src/.../policy/guard:171-178,224-228` | `/proc/1/root/<path>` escapes the read-only `/boot` kernel namespace (proven) and evades every guard block-tier path rule; `docs/storage.md` claim is false |
| 2 | LOW | Audit | `src/.../policy/audit:24-36` | Common password forms are not redacted (`mysql -p`, `PGPASSWORD=`, `sshpass -p`, bare `pass X`, `passphrase:`) |
| 3 | LOW | Logging | `src/.../event/disks_mounted:61`, `event/stopping:45`, `include/actions.php:41` | `restore.log` and `sessions.log` are unbounded; only `install.log` rotates |
| 4 | LOW | Guard | `src/.../policy/guard:116-117,151-153` | Path matchers do not canonicalise `..`, so protected-path and block rules miss `/etc/foo/../claude-code/...` style spellings |
| 5 | INFO | Install | `src/.../scripts/install-binary:56-71` | Previous-version fallback trusts a self-referential `.sha256` sidecar on flash, not the CI-pinned hash |
| 6 | INFO | Supply chain | `.github/workflows/release.yml:12-15` | A `v*` tag on any commit (not necessarily reviewed/merged) publishes a release; inherent to tag triggers, gated by push access |
| 7 | INFO | Launcher | `src/usr/local/bin/claude:76` | The emergency token lives in the session's environment (every process is root on Unraid); exfiltration still needs a guard-asked network call |
| 8 | INFO | WebGUI | `src/.../ClaudeCode.page:122` | `#command` is an Unraid `update.php` capability (CSRF-gated); the plugin uses a fixed value, but the mechanism can run any script under the doc root |

No critical findings. One high, zero medium, three low, four info.

The high finding is "beyond accepted risk" because it defeats the two controls the project
advertises as holding **even when the user approves** — the block tier ("never run from a
session, even when asked") and the kernel read-only `/boot` ("cannot write to it, whatever
it is asked"). Everything else is either an accepted text-matching limitation, correctly
documented, or requires access the attacker would already need.

---

## 1. Supply chain

**Clean.** `scripts/claude-release` imports `keys/claude-code.asc` into a throwaway
`GNUPGHOME`, requires exactly one primary key whose fingerprint equals the pinned
`31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE` (`import_key`, lines 121-145), and accepts a
release only on a `VALIDSIG` status line whose **primary-key** field (last field) is the
pinned fingerprint (`verify_signature`, lines 149-172). `BADSIG`/`ERRSIG`/`EXPKEYSIG`/
`REVKEYSIG`/`EXPSIG` all `die`. The manifest is read **only after** the signature passes
(`do_verify`, line 231-237).

`scripts/claude-release-manifest.php` is hardened against JSON-shape confusion:
`is_array && !array_is_list` for the manifest, `platforms` and the platform entry;
`version` must be a string `=== EXPECTED_VERSION`; `checksum` must be a string matching
`^[a-f0-9]{64}$`; `size` must be a positive int or absent (lines 48-78). The bash side
re-checks `^[a-f0-9]{64}$` (line 242).

Test-mode gating is correct: `CLAUDE_RELEASE_BASE_URL`, `CLAUDE_RELEASE_KEY_FILE`,
`CLAUDE_RELEASE_FINGERPRINT` each `die` unless `CLAUDE_RELEASE_TEST_MODE=1`
(lines 55-79); the key file must resolve under `tests/`; the fingerprint must be 40 hex.
None of the workflows set `CLAUDE_RELEASE_TEST_MODE`, so CI cannot be pointed at an
unverified key. On the box, `install-binary` re-validates `CLAUDE_URL` against a
**hard-coded** `https://downloads.claude.ai/.../<ver>/linux-x64/claude` (lines 32,78), so
even a tampered `.plg` entity can only ever name that host for that version, and the
pinned sha256 is still checked.

`render-plg` validates `CLAUDE_URL` against `^https://downloads\.claude\.ai/...$`
(line 122) and every substituted value forbids `@`. `lint-plg` enforces exactly one
`<URL>` file, under `/boot/config/plugins/claude-code-unraid/`, https, with a 64-hex
`<SHA256>`, matching the plugin package name; it forbids `<MD5>`, `<LOCAL>`, `/mnt` in
INLINE and `curl|wget` in INLINE, and cross-checks the pinned Claude/tmux entities against
the lock files (lines 192-291). `scripts/devenv/Dockerfile` pins the base image by digest
and every tool (shellcheck, shfmt, bats, actionlint, Slackware pkgtools) by version +
sha256. Workflows pin `actions/checkout` by commit SHA; top-level `permissions:
contents: read`, with `contents: write` only on the jobs that need it.

Info 6: `release.yml` triggers on `push: tags: v*`. GitHub does not require a tagged
commit to be on `main` or reviewed, so anyone with push access can publish a release from
an arbitrary commit. This is inherent to tag-triggered releases and bounded by repo push
access; noted, not a plugin defect. The daily bump workflow only opens a PR and never
pushes to `main` (`claude-bump.yml`), which is correct.

## 2. On-box install

**Largely clean.** `fetch_verified` (`lib.sh:335-401`) refuses a cache entry that exists
but is not a regular non-symlink file, verifies the download against the pinned sha256 and
size before `mv` into place, then re-verifies the copy that landed on flash.
`install_ram_copy` (lines 406-435) copies to a `mktemp` name in the destination dir,
`chmod`s and **verifies the temp copy** against the sha256, then `mv`s over the target; it
refuses when the target exists and is not a regular file. There is no verify→exec TOCTOU
window that an unprivileged actor could use: the verify is of the temp file that is then
atomically renamed, and the destination dir (`/usr/local/lib/claude-code-unraid`) is
root-only RAM. Symlink/hardlink swaps at the cache and RAM targets are rejected by the
`is_regular_nonlink` guards (lib.sh:269, 343, 410). URL/version/sha256 inputs are
regex-validated (`install-binary:76-83`, `install-tmux:37-48`). Flash-full is handled
(`need_kb = size*1.2`, `fetch_verified:357-363`); a read-only or unwritable flash surfaces
as a recorded error and an alert, never a failed boot (invariant 3), confirmed by the
emulated-host "corrupt cache + no network" scenario.

Info 5: the previous-version fallback (`install-binary:find_previous`, lines 56-71) trusts
`claude-<ver>.sha256` sidecars written on flash next to each cached binary, and installs
the newest cached binary that matches **its own** sidecar. The sidecar hash is therefore
self-referential — it proves "this is the file we wrote," not "this matches Anthropic's
pinned hash." An actor who can already write the flash drive could plant
`claude-<x>` + a matching sidecar and have it run if the pinned download fails. Writing
flash requires root/physical/`--boot-rw` (or finding 1), so this is an accepted
"flash is trusted" position; `docs/SPEC.md` §4 describes it. Left as info.

## 3. Launcher — token handling and the read-only `/boot` namespace

**Token handling: clean.** The emergency token is read from the flash file and exported as
`CLAUDE_CODE_OAUTH_TOKEN` only in fallback mode, never passed as an argv element
(`claude:72-80`); the shell variable is `unset` after export. It is not echoed into the
WebGUI (status reports only a boolean), not logged (only `log notice "... authenticated
with the emergency token"`, no value), and the audit hook never sees it. Info 7: because
every process on Unraid is root, any process can read `/proc/<pid>/environ` of the `claude`
process, so the token is readable by a co-resident root process; this is inherent to
putting a token in the environment (the documented, working mechanism) and exfiltration by
the agent itself still trips the guard's network ask. Acceptable.

**`--boot-rw` gating: holds.** The flag is stripped and honoured only when
`ALLOW_BOOT_RW="yes"` in the cfg, read through the non-sourcing `cfg_bool`
(`claude:101-109`); otherwise exit 80. Verified by the emulated host (exit 80 by default).

### Finding 1 (HIGH): `/proc/<pid>/root` escapes the read-only `/boot` and the guard block tier

`src/usr/local/bin/claude:115` runs the binary in a new **mount** namespace
(`unshare --mount`) and remounts `/boot` read-only there. `unshare --mount` does **not**
create a new PID namespace, so `/proc` still shows host PID 1 (emhttpd/init), which lives
in the original mount namespace where `/boot` is read-write. Writing through
`/proc/1/root/boot/...` therefore reaches the real, writable flash drive, completely
bypassing the per-namespace read-only remount. The same prefix defeats the guard's
path-based **block** rules, because the guard matches text and the paths no longer begin
with `/boot`, `/dev/sd*` or `/mnt/*`.

Proof A — the namespace escape, run in a `--privileged` dev container that mimics the
launcher (tmpfs `/boot`, then `unshare --mount` + `mount -o remount,bind,ro /boot`):

```
--- inside child namespace ---
direct write to /boot: BLOCKED (ro) as designed
/bin/sh: 4: cannot create /boot/config/go: Read-only file system
WROTE via /proc/1/root/boot/config/go : ESCAPE SUCCEEDED
--- back in host namespace, /boot/config/go now contains: ---
ESCAPED
```

Proof B — the guard's verdict on the evasion paths (dev image, Bash PreToolUse, `/boot`
read-only in-session as in a normal session):

| command | direct form | `/proc/1/root/` form |
|---|---|---|
| `dd if=x of=/dev/sda` | BLOCKED | `dd ... of=/proc/1/root/dev/sda` → **ALLOWED** |
| `cat x > /dev/sda` | BLOCKED | `cat x > /proc/1/root/dev/sda` → **ALLOWED** |
| `cp img /dev/sdb` | BLOCKED | `cp img /proc/1/root/dev/sdb` → **ALLOWED** |
| `rm -rf /mnt/user` | BLOCKED | `rm -rf /proc/1/root/mnt/user` → **ALLOWED** |
| `echo x > /boot/config/go` | ASK (when rw) | `echo x > /proc/1/root/boot/config/go` → **ALLOWED** even when rw |

`/proc/1/root/dev/sdX` is the same block device as `/dev/sdX` (the launcher does not
remount `/dev`), and `/proc/1/root/mnt/user` is the same share, so these are not just
spelling curiosities — they perform the catastrophic action while the guard stays silent
and the kernel read-only `/boot` is bypassed.

Impact: the two controls that the project says hold *even on approval* both fail with a
trivial, non-obfuscated one-liner. `docs/storage.md` states "The agent can read the flash
drive ... but cannot write to it, whatever it is asked." — this is **false** as written.
`docs/SPEC.md` §2 lists the read-only `/boot` namespace as the mitigation for "Agent
writes to the flash drive or bricks the boot config"; that mitigation is bypassable
without `--boot-rw` and without a guard ask. `docs/SECURITY.md` "What the guard cannot
catch" lists variables, eval, written-then-run scripts, interpreters and `docker exec`, but
**not** `/proc/<pid>/root` path aliasing, so the most powerful evasion is undocumented.

Mitigant (why not critical): a plain `dd ... of=/proc/1/root/dev/sda` is still a Bash
command, so Manual mode presents the usual approval prompt; a vigilant operator can refuse
it. The finding is that the block tier and the kernel `/boot` control are specifically the
backstops for when the operator does *not* scrutinise (prompt injection, rubber-stamping),
and those backstops are defeated.

Fix recommendation (defence in depth; the guard is text-matching and cannot be made
complete):
- Add a guard rule that treats a path component of `/proc/<digits>/root/`, `/proc/<digits>/cwd/`, `/proc/self/root/` (and similar `/proc/*/root` gateways) as an alias and either blocks or asks — at minimum raise an ask with a clear reason, and apply the existing block/flash/plugin-path tests to the remainder after the gateway.
- Correct `docs/storage.md` to drop the absolute "whatever it is asked" claim, and add `/proc/<pid>/root` (PID-namespace aliasing) to the `docs/SECURITY.md` "what the guard cannot catch" list and to the threat-model caveat for read-only `/boot`.
- Optionally run the launcher in a new PID namespace too (`unshare --mount --pid --fork`) so `/proc/1` is the session's own init, which removes the `/proc/1/root` gateway (does not remove `/proc/<host-pid>/root` for a PID the agent can still see without PID isolation of the whole host — so documentation remains the honest primary fix).

Added to the guard-bypass table below and to `docs/SECURITY.md`'s maintained list is
recommended.

## 4. Policy

**Baseline locks hold under the documented merge rules.** `permissions.defaultMode`,
`disableBypassPermissionsMode`, `disableAutoMode`, `disableRemoteControl` are scalars; the
`99-` baseline loads last so its scalars win over any `50-user-*` drop-in. `deny`/`allow`
and `hooks` are lists/objects that union, so a user drop-in can only **add** rules and
cannot remove the guard/audit/session hooks or the deny entries. `render-policy`
re-asserts the locks after applying the cfg toggles (lines 89-108): `defaultMode`,
`disableBypassPermissionsMode`, `env.DISABLE_UPDATES/AUTOUPDATER`, the four hook events and
a non-empty `deny` must all survive, or nothing is written. `install-policy` validates
every drop-in is a ≤1 MiB JSON object before writing it as `50-user-<sanitised>.json`
(name is `tr -c 'A-Za-z0-9._-' '_'`, `cut -c1-64`, deduped), and removes stale
`50-user-*` files it previously wrote. A project `.claude/settings.json` cannot set
`disableAllHooks` over managed hooks (platform fact) nor relocate `CLAUDE_CONFIG_DIR`.
So neither a user drop-in nor a project settings file can weaken the baseline. **Clean.**

**Editing the policy from a session requires an ask** for the ordinary tools: `sed -i`,
`tee`, `cp`, `dd`, `install`, `rsync`, `patch`, `env -S`, a `cat > file` heredoc, and the
`Write`/`Edit`/`MultiEdit`/`NotebookEdit` file tools all ASK when the target is under
`/etc/claude-code`, the launcher/helper, the plugin dir or the installed binary (verified;
see table). The expected text-matching gaps (variable assembly, `eval`, write-then-run,
`python3 -c`/`node -e`/`php -r` that open the file themselves) are ALLOWED and are
documented in `docs/SECURITY.md`. Two caveats:

- A user policy drop-in lives on flash (`/boot/config/plugins/.../policy.d/`); writing it
  is a flash write, so in a normal session the kernel read-only `/boot` blocks it — unless
  finding 1 is used, which reaches it without an ask. The merge rules still prevent
  weakening the baseline scalars, so the worst a planted drop-in does is add `allow` rules
  (self-inflicted, and the PreToolUse guard still runs). Covered by finding 1.
- Finding 4 (LOW): the guard normalises `\`, `//` and `/./` but not `..`
  (`guard:116-117` for file tools, `151-153` for Bash). A `Write` to
  `/etc/foo/../claude-code/managed-settings.json`, or a `tee /etc/foo/../claude-code/x`,
  resolves into the protected directory but is not matched. Like finding 1 this is path
  aliasing; it is lower impact because it still draws a Manual-mode prompt and the
  protected-path ask is advisory. Fix: canonicalise `..` (and the `/proc/*/root` gateway)
  before matching, or document it.

The ask-tier JSON shape is correct (`hookSpecificOutput.permissionDecision="ask"`, reason
prefixed `claude-code-unraid guard:`, exit 0) and fail-closed is correct: empty input,
non-JSON, a non-object top level and a JSON list all exit 2 (verified), and the baseline
hook entry carries `onFailure: "block"`.

## 5. Event handlers

**Clean.** Every handler sources `event-lib.sh`, which runs the body under
`timeout EVENT_TIMEOUT` (clamped 5–120 s) with SIGKILL 3 s after SIGTERM, takes
`flock /run/.../event.lock` with a 5 s wait so handlers cannot interleave, logs start/end,
and always exits 0 (emhttpd ignores the status but a non-zero would only confuse the
syslog). Nothing waits on the network. `stopping` bounds the supervised-session stop to
12 s (`run_with_timeout 12 ... stop --all --timeout 10`) and only then forces fallback.
`unmounting_disks` signals **only** PIDs the supervisor itself recorded
(`/run/.../sessions/*.pid`) that still hold a file or cwd under the data directory; it
never kills anything the plugin did not start. `stopping` *reports* unsupervised `claude`
processes (matched by `/proc/<pid>/exe` pointing at the plugin's binary) but never kills
them. `disks_mounted` touches `/mnt` only after validating the data directory is mounted
and existing, and `data-dir` refuses any path shallower than `/mnt/<x>/<share>` so creating
the leaf can never create a share (invariant 2). The array stop cannot hang on the plugin:
the hard `timeout` guarantees return. Confirmed by emulated-host scenario 4 ("stopping
finished within 15 s").

## 6. WebGUI

**Clean.** `exec.php` requires `POST` (405 otherwise), so no state change is reachable by
GET, and relies on Unraid's global CSRF enforcement in `local_prepend.php` plus the
`csrf_token` the page posts. The only request input used is `action`, matched against a
fixed allowlist (`actions.php:17`); every helper invocation uses a fixed binary and fixed
arguments through `escapeshellarg` (`status.php:ccu_run_helper`), and the `restore`
action's `setsid nohup ... restore` command contains no request data. Every value printed
into the page goes through `ccu_h` (`htmlspecialchars`, `ENT_QUOTES`), enforced by
`scripts/lint-escaping`; the sessions table splits on `|` and escapes each field. No token,
account e-mail or transcript content is read by the page. `DATA_DIR` is validated with
`^/mnt/[^\s"'`$\\]+$` plus explicit `/../` and trailing `/..` rejection
(`validate-cfg.php:66`), and `data-dir --check` re-validates server-side; drop-in names are
sanitised. Info 8: the form's `#command=/plugins/.../install-policy` is an Unraid
`update.php` capability; a crafted authenticated POST could set `#command` to another
script under the document root — this is an Unraid-level, CSRF-gated behaviour, not
specific to this plugin, and the plugin itself posts a fixed value.

## 7. Sessions and audit

**Registry parsing is robust.** `registry-lib.php` tolerates a missing/empty file, backs up
a corrupt one (`.corrupt-<ts>`) and starts fresh, normalises every entry, validates the
workspace against `^[a-z0-9][a-z0-9._-]{0,47}$`, caps at 500 entries and prunes by age.

**Registry poisoning is contained.** A prompt-injected agent that runs `claude` in an
arbitrary cwd gets a registry entry, but `registry_workspace_from_cwd` only assigns a
workspace when the cwd is under `<base>/work/<name>` and matches the workspace regex, else
null; and `registry_restore_candidates` requires a non-null workspace, an existing cwd, and
either the restore flag (set only by the plugin's own `stop --mark-restore`) or
`supervised && !ended`. A plain unsupervised session is `supervised=false`, so it is never
auto-restored. When restore does run, the session id and workspace flow to tmux as **argv**
elements (`launch_session`: `tmx new-session ... -- "${cmd[@]}"`), not through a shell, so a
hostile `session_id`/`cwd` cannot inject a command; the workspace used for the tmux session
name and `-c` dir is regex-validated. One note (info): `registry_load` casts
`session_id`/`cwd` from disk to string without re-applying the charset regex that
`session-hook` applies on write, but exploitation needs write access to the data-dir
`sessions.json`, and the values reach argv, not a shell, so no injection results.

Finding 2 (LOW): audit redaction gaps. The audit hook redacts `--password=`, `token=`,
`api_key=`, `Authorization:`, `Bearer`, `user:pass@` URLs and AWS/Anthropic/OpenAI/GitHub/
Slack key shapes, but the following common forms pass through **unredacted** (verified by
running the hook with a logger stub):

```
mysql -u root -phunter2secretpw mydb            -> ...cmd=mysql -u root -phunter2secretpw mydb
env PGPASSWORD=topsecretvalue psql              -> ...cmd=env PGPASSWORD=topsecretvalue psql
sshpass -p mysecretpass ssh host                -> ...cmd=sshpass -p mysecretpass ssh host
rclone config create r webdav pass MYSECRETxyz  -> ...cmd=... pass MYSECRETxyz
restic ...  # passphrase: correcthorsebattery   -> ... passphrase: correcthorsebattery
```

Cause: the redaction rules require a `-`/`--` prefix or a `=`/`:` immediately after a
whitelisted keyword with a `\b` boundary. `-pPASSWORD` (glued, mysql), `PGPASSWORD=`
(no word boundary before `PASSWORD`), `-p PASS` (sshpass), bare `pass X` and `passphrase:`
all miss. `docs/SECURITY.md` scopes redaction to "obvious secrets," and the audit line goes
to the RAM syslog (not flash), so the exposure is to a root reader of syslog; hence LOW.
Fix: add `(^|\s)-p` (mysql-style glued), `PG?PASSWORD`, `sshpass -p`, `passphrase`, and
`\bpass(word|phrase)?\b\s+\S+` to the redactor. Newline/control-char injection into the
syslog line is already prevented (`oneLine()` collapses `\x00-\x1f`; verified — a payload
with an embedded newline produced no second logger line).

Finding 3 (LOW): log flooding. `log()` rotates `install.log` at 512 KiB, but `restore.log`
(written by `disks_mounted` and the WebGUI `restore` action) and `sessions.log` (written by
`stopping`) are plain `>>` appends with no bound. They live in `/var/log/claude-code-unraid`
(RAM, cleared on reboot) and grow a bounded amount per operation, but an agent that loops
`claude-unraid stop/start`, or repeated restore triggers, can grow them without limit until
the next reboot. LOW. Fix: route these through the bounded `log()`/rotation, or `truncate`
them on each run.

## 8. Data handling

**Clean and documented.** Flash writes are exactly the five documented kinds (cfg,
`policy.d/`, cached binary + sidecar, `pkg/`, opt-in `emergency-token`). The only sensitive
item is the emergency token; it is written mode 0600, but FAT has no permissions, so the
real exposure is the flash SMB export — which `doctor`, `status` and the WebGUI all warn
about, and `docs/storage.md` documents with the fix. The token is opt-in. Uninstall
leftovers (cfg, `policy.d`, token, data dir) are kept deliberately and the `remove` script
prints each path and the command to delete it. `collect-diagnostics` redacts tokens,
e-mails and disk serials and never includes the token file.

---

## Guard-bypass table

Bash PreToolUse unless noted. "Expected" = what the design intends. "Actual" = observed by
running the guard in the dev image. `/boot` read-only in-session (the normal case) unless
stated. rc 2 = block; JSON ask = ask; silent = allow.

| # | command | expected | actual | caught elsewhere? | documented in SECURITY.md? |
|---|---|---|---|---|---|
| 1 | `dd if=x of=/dev/sda` | block | **BLOCKED** | — | yes |
| 2 | `dd if=x of=/proc/1/root/dev/sda` | (evades) | **ALLOWED** | Manual-mode prompt only | **no** (finding 1) |
| 3 | `cat x > /proc/1/root/dev/sda` | (evades) | **ALLOWED** | Manual-mode prompt only | **no** (finding 1) |
| 4 | `cp img /proc/1/root/dev/sdb` | (evades) | **ALLOWED** | Manual-mode prompt only | **no** (finding 1) |
| 5 | `rm -rf /proc/1/root/mnt/user` | (evades) | **ALLOWED** | Manual-mode prompt only | **no** (finding 1) |
| 6 | `echo x > /proc/1/root/boot/config/go` | (evades RO `/boot`) | **ALLOWED**; write reaches real `/boot` (proven) | Manual-mode prompt only | **no** (finding 1) |
| 7 | `c=mk; ${c}fs.ext4 /dev/sdb` (variable assembly) | evades | ALLOWED | prompt | yes |
| 8 | `eval mkfs.ext4 /dev/sdb` | evades | **BLOCKED** (string still contains `mkfs`) | — | yes (eval listed) |
| 9 | `echo mkfs... > x.sh; bash x.sh` (write then run) | evades | **BLOCKED** (literal in the write) | — | yes |
| 10 | `python3 -c "open('/dev/sda','w')"`-style interpreter | evades | ALLOWED | prompt | yes |
| 11 | `node -e ...`, `php -r ...` (open file themselves) | evades | ALLOWED | prompt | yes (interpreters) |
| 12 | `IFS=X; cmd=mkXfs; $cmd` | evades | ALLOWED | prompt | yes (variables) |
| 13 | `base64 -d <<<... > /tmp/x` (decode, no pipe to sh) | allow (write only) | ALLOWED | prompt | n/a |
| 14 | `awk 'BEGIN{system("mkfs.ext4 /dev/sdb")}'` | — | **BLOCKED** (literal matched) | — | — |
| 15 | `xargs mkfs.ext4` / `find -exec mkfs.ext4` | — | **BLOCKED** | — | — |
| 16 | `sudo -u root mkfs.ext4 /dev/sdb` | block | **BLOCKED** | — | — |
| 17 | `nohup`/`setsid`/`timeout` + `mkfs.ext4 /dev/sdb` | block | **BLOCKED** | — | — |
| 18 | `command mkfs.ext4 /dev/sdb` | block | **BLOCKED** | — | — |
| 19 | `mk\fs.ext4`, `mk""fs.ext4`, tab/newline + mkfs | block | **BLOCKED** (normalisation) | — | — |
| 20 | `mount -o remount,rw /boot` | ask | **ASK** (mounts/namespaces) | — | yes |
| 21 | `nsenter -t 1 -m -- mount ...` / `nsenter -t1 -m sh` | ask | **ASK** | — | yes |
| 22 | `unshare -m sh` / `chroot /mnt/disk1 sh` | ask | **ASK** | — | yes |
| 23 | `mount --bind /tmp /boot` | ask | **ASK** | — | yes |
| 24 | `docker run -v /boot:/b ...` / `-v /:/host` | ask | **ASK** (host-level access) | — | yes |
| 25 | `docker exec c sh -c "echo x > /boot/go"` | evades | **ALLOWED** | prompt | yes (docker exec) |
| 26 | `systemd-run mount -o remount,rw /boot` | n/a (no systemd on Unraid) | ALLOWED | — | n/a |
| 27 | `sed -i`/`tee`/`cp`/`dd`/`install`/`rsync`/`patch`/`env -S` → `/etc/claude-code` | ask | **ASK** (policy/launcher/binary) | — | yes |
| 28 | `cat > /etc/claude-code/...json <<EOF` (heredoc) | ask | **ASK** | — | yes |
| 29 | `perl -e "open(...,'/etc/claude-code/x')"` | ask (path literal present) | **ASK** | — | yes |
| 30 | `python3 -c "open('/etc/claude-code/x','w')"` with path hidden (`chr(47)`) | evades | ALLOWED | prompt | yes (interpreters) |
| 31 | `tee /etc/foo/../claude-code/x` (`..` not canonicalised) | ask | ALLOWED | prompt | **no** (finding 4) |
| 32 | `curl https://x` / `wget` / `nc -e` / `scp exfil` | ask | **ASK** (network) | — | yes |
| 33 | `plugin install\|remove\|update ...` | ask | **ASK** | — | yes |
| 34 | `smartctl -s off` / `--set=` / `-l scterc,70,70` | block | **BLOCKED** | — | yes |
| 35 | `smartctl -t short` | ask | **ASK** | — | yes |
| 36 | unparsable / empty / JSON list / non-object input | block (fail closed) | **BLOCKED** (exit 2) | onFailure:block too | yes |

Rows 2–6 and 31 are the new, undocumented evasions (findings 1 and 4). All other evasions
either fail (the literal survives into the string) or are already listed as accepted
text-matching gaps in `docs/SECURITY.md`.

## Accepted risks confirmed

These are called out in `docs/SECURITY.md` / `docs/SPEC.md` and the review confirms they
are correctly scoped and honestly described:

- **Not a security boundary.** Claude runs as root; the policy reduces accidents and casual
  prompt injection and keeps a human in the loop. The permission prompts are the real
  control. Confirmed throughout; the docs say this plainly in `README.md`, the plugin page
  and `docs/SECURITY.md`.
- **The guard matches text.** Variable assembly, `eval` where the literal is hidden,
  write-then-run with a hidden literal, interpreters (`python3 -c`/`perl -e`/`php -r`/`node
  -e`) that open devices or sockets directly, and `docker exec ...` beyond the network and
  `curl|sh` patterns are all bypasses. Verified ALLOWED; all are listed in
  `docs/SECURITY.md` (the one gap in that list is `/proc/<pid>/root` aliasing — finding 1).
- **`grep curl file` costs one prompt.** Confirmed ASK; documented as an accepted false
  positive.
- **Mounts inside the session do not propagate to the host.** Documented limitation in
  `docs/SPEC.md` §7 and `docs/storage.md`.
- **Emergency token in the environment / on FAT flash.** Opt-in; warned about on SMB
  export; passed only in fallback mode and never on argv. Confirmed.
- **Remote Control stores transcripts on Anthropic servers while connected.** Off by policy
  unless enabled; warned on the page and by `start --remote-control`.
- **`ON-BOX` items** (the unshare read-only trick on Unraid's real mount layout, the binary
  running on Unraid glibc, `.claude.json` placement, trust persistence, the exact
  `--dangerously-skip-permissions` message, tmux starting) are untested on hardware by
  design of this remote review and are tracked in `docs/TESTING.md`. Note that finding 1
  shows the unshare read-only trick, even when it works, does **not** deliver the "cannot
  write to `/boot`, whatever it is asked" guarantee that `docs/storage.md` claims.

## What could not be verified

- The namespace escape (finding 1) was proven in a Linux `--privileged` container that
  reproduces the launcher's `unshare --mount` + read-only bind-remount. It was **not** run
  on a real Unraid box; the `/proc/<pid>/root` semantics are standard Linux and
  independent of Unraid's mount layout, so the result is expected to hold on hardware, but
  the on-box confirmation belongs in `docs/TESTING.md`.
- Claude Code's own merge precedence and `disableAllHooks`-over-managed-hooks behaviour are
  taken from the documented platform facts in `CLAUDE.md`/`docs/SPIKE.md`; not independently
  re-tested against a live Claude Code binary.
- Whether Claude Code's `Write` tool passes an un-normalised `..` path to the hook
  (finding 4) depends on the CLI's own path handling and was not tested against a live
  binary; the guard-side gap (no `..` canonicalisation) is confirmed by code and by the
  `tee /etc/foo/../claude-code/x` probe.
