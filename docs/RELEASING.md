# Releasing

## The Claude Code version lock

The plugin never trusts a version string it did not verify. `release/claude-code.lock`
is the single source of truth for which Claude Code build the `.plg` installs:

```
CLAUDE_VERSION=2.1.308
CLAUDE_PLATFORM=linux-x64
CLAUDE_SHA256=<sha256 of the linux-x64 binary, from the signed manifest>
CLAUDE_URL=https://downloads.claude.ai/claude-code-releases/2.1.308/linux-x64/claude
CLAUDE_SIZE=292232560
MANIFEST_SHA256=<sha256 of manifest.json as verified>
VERIFIED_AT=<UTC timestamp>
```

`scripts/claude-release` produces it:

1. `resolve --channel stable` reads `https://downloads.claude.ai/claude-code-releases/stable`.
2. `verify --version X` downloads `X/manifest.json` and `X/manifest.json.sig`, imports
   `keys/claude-code.asc` into a throwaway `GNUPGHOME`, requires that the key's
   fingerprint is exactly `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`, runs
   `gpg --verify` and accepts only a `VALIDSIG` status line made by that key. Only then
   does it read `platforms["linux-x64"].checksum` and `.size` from the manifest. With
   `--download` it also fetches the binary and compares its sha256 and size.
3. `lock --version X [--download]` writes the lock file.

Run it through the dev image so that the same gpg, curl and php are used everywhere:

```sh
./scripts/dev-env scripts/claude-release lock --version "$(./scripts/dev-env scripts/claude-release resolve --channel stable)" --download
```

The pinned fingerprint and the base URL are constants in the script. The only overrides
are for the offline test suite and are accepted solely with `CLAUDE_RELEASE_TEST_MODE=1`,
with a key file that lives under `tests/`.

`release/tmux.lock` pins the Slackware 15.0 tmux package the same way (URL, sha256,
size). It was verified by hand against the Slackware signing key (see `docs/SPIKE.md`,
section 12) and only changes with a new manual verification.

## Automatic bump proposals

`.github/workflows/claude-bump.yml` runs daily. When the stable channel is newer than the
lock, it runs `lock --download`, pushes a `claude-bump/<version>` branch and opens a pull
request titled `claude-code: OLD → NEW` whose body carries the verification output. It
never pushes to `main`. A maintainer reviews the diff (one lock file) and merges; a plugin
release is a separate, tagged step.

Pull requests opened with the default `GITHUB_TOKEN` do not trigger CI. Configure a
fine-grained personal access token with `contents: write` and `pull-requests: write` as
the `BUMP_TOKEN` repository secret if CI should run on bump PRs automatically.

## Packaging

- `scripts/build-txz` builds `dist/claude-code-unraid-<version>-noarch-1.txz` from
  `src/` (rooted at `/`) plus `plugin/slack-desc`. Modes are set by the build
  (directories 0755, files with a `#!` line 0755, everything else 0644), CR bytes are
  stripped, and the archive is laid out exactly like `makepkg` does it. The build is
  reproducible: owner 0, mtimes from `SOURCE_DATE_EPOCH`, single-threaded xz.
- `scripts/render-plg` fills `plugin/claude-code-unraid.plg.in` from the build, the two
  lock files and the latest `CHANGELOG.md` sections, validating every value first.
- `scripts/lint-plg` checks the rendered file (well-formed XML with entity expansion,
  SHA256 on the only URL element, no `/mnt`, attributes, CHANGES, entities, and that the
  pinned Claude and tmux values match the locks). `make check` renders a dev plg and lints
  it; `make build` builds and renders a dev version into `dist/`.
- `./scripts/dev-env --root make e2e-install` runs Lime Technology's real plugin manager
  against the rendered plg inside the container: fresh install from the flash cache,
  reboot with the cache, corrupt cache without network (plg lands in `plugins-error`),
  remove, and install from a `<LOCAL>` package.

## Versioning

Unraid shows `YYYY.MM.DD.N`. The plugin manager compares versions with `strcmp`, so every
field has a fixed width: the UTC date of the tag plus one sequence digit, the tag's
position among the `v*` tags created that day (`scripts/plugin-version --tag vX.Y.Z`).
More than nine releases a day is refused. Dev builds are `0000.00.00.0-dev`
(`0000.00.00.0_dev` in the package name, because Slackware splits package names on `-`).
The semantic version is the tag and appears as `pluginVersion` in the plg and in
`CHANGES`.

## Cutting a release

1. Merge the lock bump you want to ship, if any.
2. Move the `[Unreleased]` entries in `CHANGELOG.md` under a `## [X.Y.Z] - YYYY-MM-DD`
   heading and start a new empty `[Unreleased]` section. Commit.
3. Run `./scripts/dev-env make check` and `./scripts/dev-env --root make e2e-install`.
4. Tag: `git tag -a vX.Y.Z -m "vX.Y.Z"` and push the tag. Tags containing `-`
   (`v0.1.0-beta.1`) become pre-releases, which `releases/latest/download/` skips; beta
   users install from the tag's own asset URL.
5. `.github/workflows/release.yml` runs `make check`, builds the package with the tag's
   commit date as `SOURCE_DATE_EPOCH`, renders the plg with the release asset URL,
   re-runs `lint-plg`, writes `SHA256SUMS`, and creates the GitHub release with the plg,
   the package and the checksums. The plg's `pluginURL` points at
   `releases/latest/download/claude-code-unraid.plg`, which is how installed copies find
   updates.

## Rotating the signing key

If Anthropic rotates its release signing key, download the new key from
`https://downloads.claude.ai/keys/claude-code.asc`, confirm the new fingerprint from a
second channel (Anthropic's documentation or security advisories), replace
`keys/claude-code.asc`, update `PINNED_FINGERPRINT` in `scripts/claude-release` and the
test in `tests/bats/claude-release.bats`, and describe the source of the fingerprint in
the commit message. Nothing on the Unraid box changes: the box only ever checks sha256
values that CI pinned.
