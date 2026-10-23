# Claude Code for Unraid: implementation prompt pack

This pack drives Claude Code through building a native, security-first Unraid plugin that installs the Claude Code CLI on the host. The plugin persists auth, config and sessions across reboots and restores them, and it is meant to be published in Community Applications (CA).

## What's in the pack

| File | Where it goes | Purpose |
|---|---|---|
| `CLAUDE.md` | Repo root | Standing rules Claude Code reads every session: identity, invariants, conventions, commit style |
| `docs/SPEC.md` | `docs/` in the repo | The authoritative design. Every prompt implements a part of it |
| `prompts/00-spike.md` … `prompts/12-ca-submission.md` | Keep outside the repo, or in `prompts/` | One prompt per phase, run in order |

## Before you start

1. **Pick the identity.** Edit the *Project identity* table at the top of `CLAUDE.md`:
   - plugin name
   - GitHub repo
   - minimum Unraid version
   - license

   The defaults are placeholders. Don't use `claude-code` as the plugin name: two existing plugins already install under it, and plugin names must be unique on a server.
2. **Get a test server.** Use a disposable Unraid box, ideally a VM on a trial key, with SSH key access from the machine running Claude Code. Most phases run fine without one, but the spike in phase 0 and the on-box tests in phase 10 need a real Unraid. Don't use your production server until phase 10 passes.
3. **Create the empty GitHub repo** and clone it locally. Copy `CLAUDE.md` and `docs/SPEC.md` into it.

## How to run each phase

- **One phase per fresh Claude Code session,** started in the repo directory. Paste the prompt file's contents as your first message. Starting fresh keeps context small and makes each phase re-runnable.
- **Use plan mode for phases 3–9.** Start with Shift+Tab into plan mode, review the plan, then let it build.
- **Every prompt ends with acceptance checks.** Don't move to the next phase until they pass and you've read the diff. Each phase ends with a commit; phases 3+ open a PR so CI runs.
- **Feed the spike back in.** Phase 0 writes `docs/SPIKE.md`. If it contradicts `docs/SPEC.md`, update SPEC first, then continue.

## Phase map

| # | Phase | Needs test server |
|---|---|---|
| 00 | Spike: verify assumptions on a real Unraid box | **yes** |
| 01 | Repo bootstrap, tooling, CI lint | no |
| 02 | Claude Code release verification (GPG manifest, version lock, bump workflow) | no |
| 03 | Packaging: `.txz` build, `.plg` rendering, plg lint, release workflow | no |
| 04 | On-box install/update/remove logic and binary cache | optional |
| 05 | Launcher, storage modes, config, emergency token | optional |
| 06 | Array lifecycle event handlers | optional |
| 07 | Managed policy, guard hook, audit hook | no |
| 08 | Session registry and restore | optional |
| 09 | WebGUI settings page | optional |
| 10 | End-to-end harness and on-box test plan | **yes** |
| 11 | Independent security review | no |
| 12 | Docs, CA template, support thread, first beta release | no |

## Things the research changed from the earlier design

These are already built into `docs/SPEC.md`. Worth knowing:

1. **`stopping_array` is too late.** Unraid's own `emhttp_event` script documents that disks and user shares are *already unmounted* when `stopping_array` fires. Sessions must be stopped on `stopping`, with `unmounting_disks` as a backstop. emhttp also blocks until each event script returns, so handlers need hard timeouts.
2. **A failed URL download at boot disables the plugin.** The plugin manager moves the whole `.plg` to `plugins-error` and skips it on every later boot. So the large Claude binary isn't a `<FILE URL>` element. It's fetched and verified by our own script, which degrades gracefully.
3. **Policy uses `/etc/claude-code/managed-settings.d/`.** Drop-ins merge alphabetically after `managed-settings.json`, which lets the plugin's baseline load last and user customizations sit underneath it. An invalid managed JSON file makes Claude Code refuse to start, so everything is validated before it's written.
4. **Don't assume `jq` or `tmux` exist on Unraid.** PHP CLI is guaranteed, because the plugin manager itself is PHP, so hooks and JSON handling use PHP. tmux availability is checked in the spike.
5. **CA policy on closed-source binaries.** CA's policy says closed-source plugins are not accepted, though closed-source *binaries* may be allowed at moderator discretion. Claude Code itself isn't open source. The plugin never redistributes it: it downloads from Anthropic's official release bucket and verifies the signed manifest. Phase 12 makes that case explicitly to moderators.

## About "official"

This can become an official *Community Applications* listing. It isn't an official Anthropic product, so the README and plugin page must say it is not affiliated with or endorsed by Anthropic or Lime Technology, and the name shouldn't suggest otherwise.
