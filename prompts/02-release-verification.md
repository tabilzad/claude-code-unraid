# Phase 02: Claude Code release verification and version lock

Read `CLAUDE.md`, `docs/SPEC.md` section 4, and `docs/SPIKE.md` (how the stable version is resolved).

Goal: CI can turn "the current stable Claude Code" into a **cryptographically verified** `release/claude-code.lock`, and a scheduled workflow proposes bumps as PRs.

## Tasks

1. **`keys/claude-code.asc`:** Anthropic's release signing key, downloaded from `https://downloads.claude.ai/keys/claude-code.asc`. Hard-code the expected fingerprint `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE` as a constant in the script. The script must import the key into a **temporary, isolated** `GNUPGHOME` and fail if the fingerprint doesn't match exactly.
2. **`scripts/claude-release`** (bash, runs in CI or the dev-env, never on Unraid):
   - `resolve --channel stable|latest` prints a version, using the method recorded in SPIKE.md. Validate it against `^[0-9]+\.[0-9]+\.[0-9]+$`.
   - `verify --version X` downloads `manifest.json` and `manifest.json.sig` to a temp dir, runs `gpg --verify` with `--status-fd` parsing (require `VALIDSIG` with the pinned fingerprint, not just exit code 0), and extracts `platforms["linux-x64"].checksum`, which must match `^[a-f0-9]{64}$`, plus the size if present.
   - `lock --version X` runs `verify` and writes `release/claude-code.lock` as simple `KEY=value` lines: `CLAUDE_VERSION`, `CLAUDE_PLATFORM`, `CLAUDE_SHA256`, `CLAUDE_URL`, `CLAUDE_SIZE`, `MANIFEST_SHA256`, `VERIFIED_AT`.
   - Optional `--download` flag on `verify` also downloads the binary and checks its sha256. CI uses this on bump PRs.
   - Use `curl --fail --proto '=https' --tlsv1.2`, with retries and timeouts.
3. **Tests (bats, offline):**
   - Generate a throwaway test key in the test, sign fixture manifests, and run the script with an override for the pinned fingerprint. This override must be accepted **only** when `CLAUDE_RELEASE_TEST_MODE=1` and the key file is under `tests/`.
   - Cover: good signature; bad signature; wrong-fingerprint key; manifest missing the platform; malformed checksum; non-semver version.
4. **`.github/workflows/claude-bump.yml`:**
   - runs daily plus `workflow_dispatch`
   - resolves stable and compares it with the lock; if newer, runs `lock` and `verify --download` and opens a PR (`claude-code: X → Y`) with the manifest sha256 and the verification output in the body
   - SHA-pinned actions; `contents: write` and `pull-requests: write` only on this job
   - never pushes to `main` directly
5. Commit an initial `release/claude-code.lock` produced by a real run in CI or the dev-env. If the network isn't available locally, say so and let the workflow produce it.

## Acceptance

- `make check` is green, and the new bats tests are listed in the output.
- One real `scripts/claude-release lock --version <stable>` run succeeded (paste the redacted output), or this is explicitly deferred to CI with the reason.
- PR opened from `phase/02-release-verification`.
