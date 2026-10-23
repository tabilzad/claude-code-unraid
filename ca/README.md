# Community Applications files

- `ca/claude-code-unraid.xml`: the plugin wrapper CA reads (`<Plugin>` root). Its
  `PluginURL` must be byte-for-byte the `pluginURL` of the `.plg`
  (`plugin/claude-code-unraid.plg.in`); `make lint-ca` checks that, and that both
  XML files are well formed.
- `ca_profile.xml` (repository root, where CA requires it): the repository profile.
- `ca/claude-code-unraid.png`: the icon, 256x256, not animated, not Anthropic's logo.
  Regenerate with `python3 scripts/make-icon.py ca/claude-code-unraid.png` (no
  dependencies beyond the Python standard library).
- `docs/ca-moderator-notes.md`: facts for the moderators' manual review.
- `docs/support-thread.md`: the draft of the forum support thread.

## Submitting

1. The repository must be public on GitHub, the account must have 2FA enabled, and an
   OSI-approved license file must sit at the repository root (`LICENSE`, MIT).
2. Post the support thread (Plugin Support on `forums.unraid.net`). Put its URL into
   `plugin/claude-code-unraid.plg.in` (`support` entity), `ca/claude-code-unraid.xml`
   (`Support`) and `ca_profile.xml` (`Forum`), then cut the release. GitHub issues work
   as the support link until then.
3. Make sure `https://github.com/tabilzad/claude-code-unraid/releases/latest/download/claude-code-unraid.plg`
   resolves (every tag is a full release; see `docs/RELEASING.md`).
4. Open <https://ca.unraid.net/submit/new>, enter the repository URL, run **Validate**
   and **Scan**, and fix whatever the validator reports. Plugins are reviewed by hand;
   `docs/ca-moderator-notes.md` has the facts the reviewers will ask about (plugin
   versus container, the closed-source binary, root, flash footprint, boot safety).
5. After acceptance, the entry shows up in Apps within a few hours. Later releases need
   no resubmission: CA reads the plg at `PluginURL`.
