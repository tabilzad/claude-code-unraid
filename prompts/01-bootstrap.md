# Phase 01: Repo bootstrap, tooling, CI lint

Read `CLAUDE.md` and `docs/SPEC.md`. This phase creates the skeleton and the quality gates that every later phase relies on. **No plugin behaviour yet.**

## Tasks

1. Create the repo layout from `CLAUDE.md` with placeholder `.gitkeep` files where needed. Use the `PLUGIN` value from the identity table everywhere.
2. Add the project files:
   - `LICENSE` with the identity's license and the copyright holder taken from git config
   - `NOTICE`, which credits `mygrexit/claude-unraid-manager` (MIT); its guard is adapted in phase 07
   - `.editorconfig`, `.gitignore` (build output, `*.txz`, `dist/`, `.tmp/`)
   - a `README.md` stub with a not-affiliated disclaimer
   - a `SECURITY.md` stub with private reporting via GitHub security advisories
   - `docs/SECURITY.md` and `docs/TESTING.md` placeholders
3. Add a `Makefile` with these targets:
   - `lint`: shellcheck, shfmt check, `php -l` on all PHP, xmllint on the plg template once it exists
   - `test`: bats, plus a minimal PHP test runner (plain PHP assertions are fine; no Composer unless clearly needed)
   - `check`: `lint` + `test`
   - `build`: stub for now
   - `fmt`
4. Make the dev tooling reproducible:
   - Use `scripts/dev-env` (Docker-based), with pinned images **by digest**, to run shellcheck, shfmt, bats-core, php 8.x and xmllint.
   - `make check` must run with only Docker installed.
   - Document how to update the digests.
5. Add `.github/workflows/ci.yml` that runs `make check` on push and PR:
   - pin every action by full commit SHA, with a version comment
   - set least-privilege `permissions:` (`contents: read`)
   - add `.github/dependabot.yml` for actions and Docker digests
6. Add a sample bats test and a sample PHP test so the harness is proven, plus a `tests/helpers/` fixture builder that creates a fake root (`$FAKEROOT/boot/config/...`, `$FAKEROOT/mnt/...`, `$FAKEROOT/proc/self/mountinfo`, `$FAKEROOT/var/local/emhttp/var.ini`). All scripts must take a `ROOT` env var prefix (default empty) so tests can point them at the fake root. Document this convention in `CLAUDE.md` under Coding conventions.

## Out of scope

The Claude binary, the plg contents, any runtime script.

## Acceptance

- `make check` passes locally through Docker. Paste the tail of the output.
- The CI workflow is valid: run `actionlint` through the dev-env if you can.
- Commit(s) on `phase/01-bootstrap`, then open a PR. Brief messages, no attribution lines.
