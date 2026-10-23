# Notes for the Community Applications moderators

Factual notes for the review of the **Claude Code for Unraid** plugin submission
(`claude-code-unraid`). Everything here can be checked in the repository:
<https://github.com/tabilzad/claude-code-unraid>.

## 1. Why a plugin and not a Docker application

The plugin's purpose is host-level diagnostics and recovery: running Claude Code on the
host so that it can read the syslog, `smartctl`, `zpool`/`btrfs` state, `/boot/config` and
the real process list, and so that it keeps working **with the array stopped and Docker
disabled** (it falls back to a RAM-only configuration until `disks_mounted`). A container
cannot run while Docker is down and only sees what is bind-mounted into it. The plugin also
hooks the array events (`disks_mounted`, `stopping`, `unmounting_disks`) to stop its own
sessions before the shares disappear and to bring them back afterwards.

## 2. Closed-source binary disclosure

Claude Code itself is **not open source**. The plugin is MIT and contains no Anthropic
code. It never redistributes Claude Code:

- At install time, a script in the package downloads the `linux-x64` binary from Anthropic's
  official release bucket, `https://downloads.claude.ai/claude-code-releases/<version>/linux-x64/claude`.
- The sha256 it must match is pinned in the `.plg` (`claudeSHA256` entity). That value is
  produced by CI from Anthropic's `manifest.json` for that version **after verifying the
  manifest's GPG signature** against Anthropic's published release-signing key, fingerprint
  `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE` (`scripts/claude-release`,
  `release/claude-code.lock`).
- The box verifies the sha256 before moving the file to the flash cache, again before
  copying it to RAM, and again on every boot before `claude` can run.
- Updates are not automatic: Claude Code's own updater is disabled (`DISABLE_UPDATES=1`,
  `DISABLE_AUTOUPDATER=1` in managed settings). A version bump is a reviewed pull request
  in the plugin repository and ships as a new plugin release.

The plugin also fetches the unmodified **Slackware 15.0 tmux package** (ISC licensed) from
an official Slackware mirror, pinned by sha256 (signature verified by hand when pinned), and
extracts only `usr/bin/tmux` into the plugin's own directory. It does not install anything
system-wide and does not conflict with NerdTools.

## 3. What runs as root and the safeguards

Like every plugin, everything runs as root. Specific to this one:

- Claude Code runs as root inside a **private mount namespace with `/boot` read-only**;
  a per-session opt-out exists and is off by default. The review found that
  `/proc/<pid>/root` of a host process reaches the writable host view; the guard asks
  before that path is used and the documentation says so plainly (no PID namespace,
  because the plugin exists to let the agent see host processes).
- A **managed Claude Code policy** (`/etc/claude-code/managed-settings.d/99-claude-code-unraid-baseline.json`)
  is restored on every boot: Manual permission mode, bypass mode disabled, auto mode and
  Remote Control disabled by default, a deny list for catastrophic commands, an allow list of
  read-only diagnostics, and three hooks: a **guard** (blocks `mkfs`/`wipefs`/`dd` to disks/
  `rm -rf /mnt`/`zpool destroy`/SMART state changes; forces a prompt for network access,
  container host access, mounts, cron, service restarts, plugin changes and edits to its own
  policy), an **audit** log to the syslog, and the session registry.
- The plugin's own event handlers run under a hard 20 s timeout and never kill processes
  they did not start.
- The WebGUI page uses Unraid's `update.php` and CSRF enforcement; its action endpoint has a
  fixed allowlist and never passes request data to a shell; every value is escaped.

The documentation states plainly that this is not a security boundary and that the user's
permission prompts are the control (`README.md`, `docs/SECURITY.md`).

## 4. Flash write footprint

Under `/boot/config/plugins/claude-code-unraid/`: the plugin package (about 100 KB), the
current and the previous Claude Code binary (about 280 MB each, with `.sha256` sidecars),
the tmux package (360 KB), the settings file, user policy drop-ins, and an optional emergency
token the user creates on purpose. Nothing else is written to the flash drive: transcripts,
logs and runtime state live under the data directory (a share) and `/run`, `/var/log`.

## 5. Failure behaviour and boot safety

- The only `<FILE>` element with a `<URL>` is the plugin's own small package, cached on
  flash with `<SHA256>`; a boot with a valid cache downloads nothing.
- The large binary is never a `<FILE URL>` element: a failed download leaves the plugin
  installed and reports through a notification, `claude-unraid status` and the settings page
  (degraded mode falls back to the previous verified version when one is cached).
- Every inline install step except the package install itself exits 0; the install never
  lands the `.plg` in `plugins-error` because of the network.
- The end-to-end harness (`tests/e2e/emulated-host.sh`) runs Lime Technology's real
  `plugin` script and pkgtools through install, reboot, corrupt cache, update and remove.
  Results of the hardware checklist, per release, are in `docs/TESTING.md` (Results).

## 6. Security review

An independent review of the repository, with a table of known guard bypasses, is in
`docs/security-review-2026-10-23.md`; `docs/SECURITY.md` carries the accepted risks.
