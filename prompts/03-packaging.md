# Phase 03: Packaging, `.plg` rendering, plg lint, release workflow

Read `CLAUDE.md` (invariants 1, 3, 4, 9), `docs/SPEC.md` sections 3–5, and `docs/SPIKE.md`.

Study these reference implementations before designing anything, and summarize what you'll copy and what you'll avoid:
- `unraid/apprise-plugin` (Lime Technology's own plugin): its `.plg` entity layout, release workflow and plugin metadata linting
- `unraid/webgui`, `emhttp/plugins/dynamix.plugin.manager/scripts/plugin`: exact `<FILE>` semantics (existing file kept unless the hash mismatches; a URL download failure aborts the install and moves the plg to `plugins-error`; `Min`/`Max`; `Method`; `Run`; `INLINE`)

Use plan mode and show me the plan first.

## Tasks

1. **`scripts/build-txz`:**
   - Build `dist/PLUGIN-<pluginver>.txz` from `src/` with correct ownership (root:root) and modes: dirs 0755, scripts and event handlers 0755, everything else 0644.
   - Strip CRLF.
   - Fail if any event handler or script isn't executable after build.
   - Use `makepkg` in a pinned-by-digest Slackware container if that's practical, otherwise a reproducible `tar --sort=name --mtime=@SOURCE_DATE_EPOCH --owner=0 --group=0 | xz` that `upgradepkg` accepts. Prove it either way with a test that installs the txz into a fake root.
2. **Versioning:** plugin version `YYYY.MM.DD.N` (fixed width, so string comparison works; note why). It's derived from the tag in CI, or `0000.00.00.0-dev` locally.
3. **`plugin/PLUGIN.plg.in` + `scripts/render-plg`:**
   - Entities: `name`, `author`, `version`, `pluginURL` (= `https://github.com/OWNER/REPO/releases/latest/download/PLUGIN.plg`), `txzURL`, `txzSHA256`, plus `CLAUDE_VERSION`, `CLAUDE_SHA256` and `CLAUDE_URL` from the lock file.
   - `<PLUGIN>` attributes: `name author version pluginURL min support launch icon`.
   - `<CHANGES>` rendered from `CHANGELOG.md` (latest few entries).
   - FILE order:
     1. an INLINE pre-install that creates dirs
     2. the txz `<FILE Name="/boot/config/plugins/&name;/pkg/&name;-&version;.txz">` with `<URL>` and `<SHA256>`
     3. an INLINE `Run="/bin/bash"` that `upgradepkg --install-new`s it and **removes older cached txz files**
     4. an INLINE that calls `/usr/local/emhttp/plugins/&name;/scripts/install-binary` with the pinned Claude entities passed as **environment variables**
     5. an INLINE that installs the policy and prints a summary
     6. a `Method="remove"` INLINE implementing SPEC section 5's remove flow by calling a script from the package, not inline logic
   - The large Claude binary is **not** a `<FILE URL>` element (invariant 3).
4. **`scripts/lint-plg`** (run in `make check`), which fails on any of:
   - the XML isn't well-formed after entity expansion
   - a `<FILE>` with `<URL>` lacks `<SHA256>`
   - a URL FILE has a target outside `/boot/config/plugins/PLUGIN/`
   - `version`/`pluginURL`/`min`/`support` are missing
   - an entity is unused or undefined
   - an INLINE references `/mnt`
   - CHANGES is empty
   - the pinned `CLAUDE_SHA256` doesn't match the lock file
5. **`.github/workflows/release.yml`**, on tag `v*`:
   - `make check`, build txz, render plg with the release URLs and sha256s, then re-run `lint-plg` on the rendered file
   - create the GitHub release with `PLUGIN.plg` and the txz as assets
   - attach a `SHA256SUMS`
   - SHA-pinned actions, least privilege
   - pre-releases for `-beta` tags
6. **Tests:**
   - bats tests for `build-txz` (perms, CRLF, contents list), `render-plg` (golden-file test on a fixture lock and version), and `lint-plg` (one failing fixture per rule)
   - an install test that runs Lime's real `plugin` script against the rendered plg inside a container with a fake `/boot`. Vendor that script under `tests/vendor/` with its GPLv2 header and a note that it's test-only. Use `LOCAL` file overrides so no network is needed, and assert that the plg succeeds with the cached files present and that the remove method runs.

## Acceptance

- `make check` is green; `make build` produces the txz and a rendered plg locally (dev version); `lint-plg` passes on it.
- The plugin-manager install test passes in the container. Paste the relevant output.
- PR from `phase/03-packaging`. In the PR body, list which apprise-plugin patterns were adopted.
