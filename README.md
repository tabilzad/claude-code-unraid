# Claude Code for Unraid

An Unraid OS plugin that installs the [Claude Code](https://code.claude.com) CLI
natively on the Unraid host, keeps its login, settings and conversations across
reboots, brings supervised sessions back after the array starts, and wraps the
agent in an enforced security policy.

> **Not affiliated.** This is a community project. It is not affiliated with,
> endorsed by, or supported by Anthropic PBC or Lime Technology, Inc. Claude Code
> is proprietary Anthropic software; the plugin downloads it from Anthropic's
> official release servers at install time and never redistributes it.

> **Root access.** Claude Code runs as root on your server. The plugin's policy
> (manual permission mode, no bypass mode, a command guard, an audit log, a
> read-only flash drive) reduces accidents. It is not a security boundary: the
> permission prompts are your control. Read `docs/SECURITY.md` before installing.

Status: **pre-release, under construction.** Nothing is published yet; follow the
phases in `prompts/` and `docs/SPEC.md`.

## Development

Only Docker is required:

```sh
./scripts/dev-env make check   # lint + tests inside the pinned image
./scripts/dev-env bash         # shell in the image
```

With shellcheck, shfmt, bats, php and xmllint installed locally, plain `make check`
works too. `docs/SPEC.md` is the authoritative design; `CLAUDE.md` lists the
invariants every change must keep.

## License

MIT for the plugin (see `LICENSE`). Third-party notices are in `NOTICE`.
Claude Code itself is governed by Anthropic's terms.
