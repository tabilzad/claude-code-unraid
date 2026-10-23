# Phase 09: WebGUI settings page

Read `CLAUDE.md`, `docs/SPEC.md` section 12, and the patterns in `unraid/webgui`:
- how built-in `dynamix` `.page` files declare `Menu`, `Title` and `Icon`
- how they post settings through `/update.php` (`#file=` and `csrf_token`)
- how `local_prepend.php` enforces CSRF
- how built-in pages open a live log in a terminal window (`openTerminal` or the equivalent in the target Unraid version)

Use plan mode, and show me a text wireframe first.

## Tasks

1. **`src/.../PLUGIN.page`:**
   - `Menu="Utilities"`, `Title="Claude Code"`, plus an icon from the built-in icon set; no external assets
   - the page header shows the not-affiliated disclaimer
2. **Status panel:** data from `claude-unraid status --json`. Add a `--json` mode to the helper if it's missing, and keep the schema stable and documented. Show:
   - plugin version and Claude version
   - binary verify state (with the error if degraded)
   - mode, DATA_DIR and whether it's on `/mnt/user` FUSE
   - auth present yes/no; **never show any token or account email** (an email is PII on a shared screen; show a boolean only)
   - the policy files loaded
3. **Settings form:** the cfg keys from SPEC section 13, with inline help. Save through `/update.php` to `/boot/config/plugins/PLUGIN/PLUGIN.cfg`, then trigger `install-policy` and re-render (use the standard `#command` pattern if available, else a POST to `include/exec.php`).
   - Validate on the server, not just in JS. DATA_DIR must pass `scripts/data-dir --check` before it's saved.
4. **Actions** go to `include/exec.php`:
   - CSRF is verified (reuse the global enforcement; don't roll your own unless you must)
   - action allowlist: `verify`, `restore`, `stop-all`, `status`, `log`
   - every shell call uses `escapeshellarg` with fixed binaries
   - responses are JSON
   - nothing user-controlled reaches a shell unescaped
5. **Sessions table:** workspace, state, started, and a copyable `claude-unraid attach <ws>`. No in-browser terminal in v1.
6. **Warnings banner:** the SPEC section 12 conditions.
7. **`README.md` in the plugin dir:** this is the plugin manager's description, so keep it short, with the disclaimer.

## Tests

- `php -l` on all files.
- PHP tests for `exec.php`'s action dispatch: unknown action rejected; argument injection attempts rejected; JSON shape.
- A static check, in `lint` or a test, that no `.page` or PHP file echoes a variable without `htmlspecialchars`. A simple scanner with an allowlist file for justified exceptions is fine.

## Acceptance

- `make check` is green.
- Screenshots aren't possible here, so give me on-box steps for: the page renders on the latest stable Unraid; saving the cfg re-renders the policy; the actions work; a POST without CSRF is rejected (give me a curl command to prove it); light and dark theme readable.
- PR from `phase/09-webgui`.
