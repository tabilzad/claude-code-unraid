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

## Automatic bump proposals

`.github/workflows/claude-bump.yml` runs daily. When the stable channel is newer than the
lock, it runs `lock --download`, pushes a `claude-bump/<version>` branch and opens a pull
request titled `claude-code: OLD → NEW` whose body carries the verification output. It
never pushes to `main`. A maintainer reviews the diff (one lock file) and merges; a plugin
release is a separate, tagged step (phase 03).

Pull requests opened with the default `GITHUB_TOKEN` do not trigger CI. Configure a
fine-grained personal access token with `contents: write` and `pull-requests: write` as
the `BUMP_TOKEN` repository secret if CI should run on bump PRs automatically.

## Rotating the signing key

If Anthropic rotates its release signing key, download the new key from
`https://downloads.claude.ai/keys/claude-code.asc`, confirm the new fingerprint from a
second channel (Anthropic's documentation or security advisories), replace
`keys/claude-code.asc`, update `PINNED_FINGERPRINT` in `scripts/claude-release` and the
test in `tests/bats/claude-release.bats`, and describe the source of the fingerprint in
the commit message. Nothing on the Unraid box changes: the box only ever checks sha256
values that CI pinned.
