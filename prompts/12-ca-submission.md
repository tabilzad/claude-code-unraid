# Phase 12: Docs, CA template, support thread, first beta release

Read `CLAUDE.md`, `docs/SPEC.md`, `docs/SECURITY.md` and `docs/TESTING.md` (hardware results), plus:
- the CA submission help: `https://ca.unraid.net/submit/help`, `.../repository-xml`, `.../xml-field-reference`
- the CA application policies thread: `https://forums.unraid.net/topic/87144-ca-application-policies-notes/`

Fetch these and summarize the rules that apply to plugins before writing anything.

## Tasks

1. **`README.md`, user-facing:**
   - what it is
   - why a plugin rather than a container: it works with the array stopped and Docker disabled, for recovery and diagnostics
   - the not-affiliated disclaimer (Anthropic, Lime Technology)
   - requirements: Unraid version, a Claude subscription or API key
   - install (CA, or the manual plg URL)
   - first login
   - workspaces and sessions
   - security model summary with a link to `docs/SECURITY.md`; make the "this is root; prompts are your control" message prominent and plain
   - storage and persistence, the emergency token, Remote Control
   - uninstall and what's left behind
   - troubleshooting with `claude-unraid doctor` and `collect-diagnostics`
   - licensing: the plugin is MIT; Claude Code is proprietary Anthropic software downloaded from Anthropic's servers at install and governed by Anthropic's terms; the plugin never redistributes it
2. **`CHANGELOG.md`:** Keep a Changelog format, with a `0.1.0-beta.1` entry. It feeds the plg `<CHANGES>`.
3. **CA files in `ca/`:**
   - `PLUGIN.xml`: `<Plugin>` with `Name`, `PluginURL` (the release latest-download URL), `Support`, `Project`, `Overview`, `Category`, `Icon` (repo-hosted PNG; not animated; not Anthropic's logo), `License`, `MinVer`, `Beta=true`, `Changes`
   - `ca_profile.xml`, per the help pages
   - The overview must be accurate and modest.
4. **`docs/ca-moderator-notes.md`:** a short, factual note for the submission covering:
   1. plugin vs docker justification (host-level diagnostics and recovery, array stopped)
   2. closed-source binary disclosure: Claude Code isn't open source; we download it from Anthropic's official bucket and verify Anthropic's GPG-signed manifest with a pinned fingerprint; nothing is redistributed
   3. what runs as root and the policy safeguards
   4. flash write footprint
   5. that it fails gracefully and never breaks boot
   6. a link to the security review
5. **`docs/support-thread.md`:** a draft first post for `forums.unraid.net` Plugin Support. Cover the summary, install, the security notes, how to report issues with diagnostics, known limitations, and the disclaimer. I'll post it myself.
6. **Release:** bump to `0.1.0-beta.1`, then tag `v0.1.0-beta.1` *after I approve*. Before tagging, run through and report:
   - CI green; e2e green
   - hardware checklist passed (from `TESTING.md`)
   - the rendered plg installs from the actual release URL on the test box
   - `lint-plg` green on the release asset

## Acceptance

- Docs, CA files and moderator notes are committed; the PR is opened.
- **Stop before tagging** and give me the pre-release checklist results. After I approve, tag, watch the release workflow, then give me the final plg URL and the next steps for the CA submission form, which I'll submit myself.
