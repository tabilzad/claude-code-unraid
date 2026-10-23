# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The plugin version shown
in Unraid is `YYYY.MM.DD.N` (release date and sequence number); the semantic version
below is the release tag.

## [Unreleased]

### Added

- Repository skeleton, Docker-based dev environment and CI.
- `scripts/claude-release`: resolves the stable Claude Code version, verifies the
  GPG-signed release manifest against the pinned Anthropic key and pins the
  `linux-x64` sha256 in `release/claude-code.lock`. A daily workflow proposes bumps.
- Packaging: reproducible `.txz` build, `.plg` rendering from a template, plg lint
  and the tag-driven release workflow.
