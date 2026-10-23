# CLAUDE.md

This repo builds an Unraid OS plugin that installs the Claude Code CLI natively on an Unraid host. It persists Claude's config, auth and sessions across reboots, restores sessions after the array starts, and enforces a security policy around an agent that runs as root. `docs/SPEC.md` is the authoritative design. Read it before changing behaviour, and update it in the same commit when behaviour changes.

## Project identity

Edit this table once. Everything else refers to these values.

| Key | Value |
|---|---|
| Plugin name (`PLUGIN`) | `claude-code-unraid` |
| Display name | Claude Code for Unraid |
| CLI helper | `claude-unraid` |
| GitHub repo | `tabilzad/claude-code-unraid` |
| Minimum Unraid version | `7.0.0` (PHP 8.3+, glibc 2.40+; see docs/SPIKE.md) |
| License | MIT |
| Support URL | GitHub issues until the forum thread exists |

`PLUGIN` is used for every path: `/usr/local/emhttp/plugins/PLUGIN`, `/boot/config/plugins/PLUGIN`, `/var/log/plugins/PLUGIN`, `/run/PLUGIN`, syslog tag `PLUGIN`. Never hard-code a different name.

## Invariants: never break these

1. **Flash writes are rare and deliberate.** `/boot` is a USB stick. Only these go there: the cached binary, cached `.txz` packages, `PLUGIN.cfg`, user policy drop-ins, and the opt-in emergency token. Never write transcripts, logs or anything chatty to `/boot`.
2. **Nothing touches `/mnt` before `disks_mounted` or after `stopping`.** Paths under `/mnt/user/...` that don't exist must never be created: on Unraid, creating one silently makes a new share. Validate that a configured path exists before using it.
3. **A boot must never fail because of this plugin.** No `<FILE URL>` element may be able to fail at boot when its cached copy is valid. If the Claude binary can't be fetched or verified, the plugin still installs, `claude` reports why, and a notification is raised. The `.plg` must never land in `/boot/config/plugins-error` because of us.
4. **Every downloaded artifact is verified.**
   - The Claude binary is verified against a SHA256 that CI took from Anthropic's GPG-signed `manifest.json`, pinned in the `.plg`.
   - Our own `.txz` files carry `<SHA256>` in their `<FILE>` elements.
   - Nothing is ever `curl | sh`.
5. **Event scripts return fast.** emhttp blocks until they exit. Every event handler has a hard total timeout (default 20 s), backgrounds anything slow, and never waits on network.
6. **Managed policy is never weakened by the plugin.** The baseline drop-in loads last. User drop-ins can add rules but can't override the baseline's locks. Any JSON is validated before it's written to `/etc/claude-code/`, because an invalid managed settings file makes Claude Code refuse to start.
7. **No secrets in logs, HTML or process args.** Tokens are never passed on a command line, echoed into the WebGUI, or written to syslog. The audit hook truncates commands and redacts obvious secrets.
8. **We never redistribute Claude Code.** The binary is only ever downloaded from Anthropic's official release bucket, `https://downloads.claude.ai/claude-code-releases/`.
9. **Idempotence.** Install, update, remove and every event handler can run twice in a row, or after a crash, without damage.
10. **No implied endorsement.** Every user-facing surface says the plugin is not affiliated with Anthropic or Lime Technology.

## Platform facts (verified; see docs/SPIKE.md for the box-level ones)

- Unraid's root filesystem is RAM. Only `/boot` (FAT, USB) and `/mnt/*` (array and pools) persist.
- Plugins reinstall from `/boot/config/plugins/*.plg` on every boot.
- The plugin manager processes `<FILE>` elements in order:
  - An existing file is kept unless its `<SHA256>`/`<MD5>` mismatches, in which case it is re-downloaded.
  - A failed download aborts the install and moves the `.plg` to `plugins-error`.
  - `Min`/`Max` attributes gate individual files by Unraid version.
- Reference implementation: `unraid/webgui`, `emhttp/plugins/dynamix.plugin.manager/scripts/plugin`.
- Event scripts live at `/usr/local/emhttp/plugins/PLUGIN/event/<event>` and must be executable. Order:
  - start: `driver_loaded`, `starting`, `array_started`, `disks_mounted`, `svcs_restarted`, `docker_started`, `libvirt_started`, `started`
  - stop: `stopping`, `stopping_libvirt`, `stopping_docker`, `stopping_svcs`, `unmounting_disks` (shares still mounted), `stopping_array` (**already unmounted**), `stopped`

  Source: `unraid/webgui` `sbin/emhttp_event`.
- WebGUI POSTs require `csrf_token`; it's enforced in `local_prepend.php`. Follow the patterns in existing `dynamix` pages.
- Guaranteed on the host: bash, PHP CLI (8.3 on 7.0-7.2, 8.4 on 7.3+), coreutils, util-linux (`unshare`, `flock`), `logger`, `sha256sum`, `wget`, `curl`, `upgradepkg`/`installpkg`, libevent and ncurses. **Not** guaranteed: `jq`, `tmux`, `screen`, `gpg`. Use PHP for JSON on the box. tmux is bundled by the plugin from a pinned Slackware 15.0 package (docs/SPIKE.md section 12).
- Claude Code:
  - managed settings live in `/etc/claude-code/managed-settings.json` plus `/etc/claude-code/managed-settings.d/*.json`, merged alphabetically, with managed precedence over everything
  - `CLAUDE_CONFIG_DIR` relocates `~/.claude` *and* `.claude.json`
  - `DISABLE_UPDATES=1` blocks every update path
  - the CLI refuses `--dangerously-skip-permissions` as root
  - hooks receive `session_id`, `cwd`, `transcript_path` and `hook_event_name` on stdin
  - a user `disableAllHooks` can't disable managed hooks

## Repo layout

```
src/                     # files packaged into the .txz, rooted at /
  usr/local/emhttp/plugins/PLUGIN/   # pages, php, scripts, event/, policy/
  usr/local/bin/                     # claude launcher, claude-unraid helper
plugin/PLUGIN.plg.in     # plg template; rendered by scripts/render-plg
plugin/slack-desc        # Slackware package description packed into the txz
release/claude-code.lock # pinned Claude Code version + verified sha256 (CI-owned)
release/tmux.lock        # pinned Slackware tmux package (hand-verified, see SPIKE)
keys/                    # Anthropic release signing key (fingerprint pinned in code)
scripts/                 # build-txz, render-plg, lint-plg, lint-ca, plugin-version, claude-release, dev-env, make-icon.py
tests/bats, tests/php    # unit tests; tests/helpers/ fixtures; tests/fixtures/ golden files
tests/e2e/               # plugin-manager and emulated-host scenarios (run as root in dev-env)
tests/vendor/unraid/     # Lime's plugin manager script, test-only (GPLv2)
ca/                      # CA plugin wrapper XML, icon, README; ca_profile.xml sits at the repo root (CA requires it there)
docs/                    # SPEC, SPIKE, SECURITY, TESTING, RELEASING, user docs
```

## Coding conventions

- **Shell:** bash, `set -euo pipefail`. It must pass `shellcheck` (no blanket disables) and `shfmt -i 2 -ci`. Quote everything. Use `mktemp` under `/run/PLUGIN` or `/tmp`, never predictable temp names.
- **PHP:** 8.x, `declare(strict_types=1)` in non-page files. It must pass `php -l`. Escape all output with `htmlspecialchars`. Never pass user input to a shell without `escapeshellarg`. Actions go through an allowlist.
- **Logging:** `logger -t PLUGIN` for anything an admin should see. Plugin-private logs go to `/var/log/PLUGIN/` (RAM), and the logs must be bounded.
- **Config:** `/boot/config/plugins/PLUGIN/PLUGIN.cfg`, `KEY="value"`, with defaults in `src/.../default.cfg`. Read it with a parser that never `source`s user-editable files.
- **Tests:** every script gets bats tests that run without a real Unraid (fixtures for `/boot`, `/mnt`, `/proc/self/mountinfo`, emhttp ini files). A bug fix gets a regression test.
- **`ROOT` prefix:** every script that touches an absolute host path prefixes it with `${ROOT:-}` (shell) or `getenv('ROOT')` (PHP), for example `"${ROOT:-}/boot/config/plugins/PLUGIN"`. `ROOT` is empty on a real box; tests point it at a fake root built by `tests/helpers/fixtures.bash` (`make_fakeroot`). Commands that the host provides (`logger`, `notify`, `upgradepkg`, `unshare`) are looked up on `PATH` or under `${ROOT:-}/usr/local/emhttp/...` so that the fixtures can stub them.
- **Dev environment:** `./scripts/dev-env make check` runs everything inside the pinned Docker image (`scripts/devenv/Dockerfile`); only Docker is required. Plain `make check` works where the tools are installed. The Dockerfile header says how to bump the pinned digests and tool checksums.
- Prefer small single-purpose scripts over one large one.

## Workflow

- Run `make check` before you claim anything is done. It runs lint, tests and plg lint. Paste the tail of its output in your report.
- Don't claim something works on Unraid unless it was run on Unraid. Say "untested on hardware" otherwise.
- If the spec is wrong or ambiguous, stop and say so. Don't invent behaviour. Propose a SPEC change.
- **Commits:** brief, imperative, 2–3 sentences at most. **No `Co-Authored-By` or other attribution lines.** One logical change per commit.
- Branch per phase (`phase/NN-name`), with a PR to `main`. CI must be green before merge.
- Never commit secrets, real tokens, or files from a real `/boot`.
