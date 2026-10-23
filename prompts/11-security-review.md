# Phase 11: Independent security review

Run this in a **fresh session**, ideally with a different model or with the Claude Security plugin if it's installed. The reviewer must not be the session that wrote the code.

Read `CLAUDE.md`, `docs/SPEC.md` (sections 2 and 9 especially) and `docs/SECURITY.md`, then review the whole repo adversarially. You're looking for ways the plugin makes an Unraid server less safe than not having it, beyond the accepted risk that a root agent can do root things when the user approves.

## Review checklist

1. **Supply chain:**
   - Can CI be tricked into locking an unverified binary? Check fingerprint pinning, `VALIDSIG` parsing, the test-mode override gating, and that the platform key extraction can't be confused by JSON shape.
   - Can a release be published from an unreviewed commit?
   - Are workflow permissions minimal?
   - Are all actions and images pinned?
2. **On-box install:**
   - TOCTOU between verify and exec
   - symlink and hardlink attacks on `/run/PLUGIN`, `/tmp`, and the flash cache paths
   - partial-write states
   - regex validation of the URL, version and sha256 inputs
   - behaviour when the flash is full or read-only
3. **Launcher:**
   - Env leakage of the token: argv, `/proc/<pid>/environ` readability (who can read it on Unraid?), child processes
   - Does `--boot-rw` gating hold?
   - Can the ro-`/boot` namespace be escaped by the agent without a guard prompt (remount, nsenter, `/proc/1/root`, `docker run -v /boot`)? List each path and whether the guard catches it.
4. **Policy:**
   - Can a user drop-in or project settings weaken the baseline locks? Verify against Claude Code's documented merge rules.
   - Can the agent edit the policy without an ask prompt via Write/Edit tools, `sed`, `tee`, `cp`, `python`?
   - Guard bypasses: build a table of bypass attempts and results (variables, `eval`, scripts written then run, heredocs, `env -S`, aliases, `busybox`). Bypasses are expected (it's text matching), but the important ones must be documented honestly in SECURITY.md.
5. **Event handlers:** can anything hang the array stop? Kill anything we didn't start? Touch `/mnt` at the wrong time?
6. **WebGUI:**
   - CSRF on every state-changing request
   - XSS in every echoed value
   - command injection in `exec.php`
   - path traversal in DATA_DIR and in the policy drop-in names
   - info disclosure: token, email, session ids
7. **Sessions and audit:**
   - `sessions.json` parsing robustness
   - registry poisoning by a malicious project
   - audit log redaction gaps
   - log flooding
8. **Data handling:** what is written to flash, and is any of it sensitive? Are uninstall leftovers documented?

## Output

- `docs/security-review-<date>.md`: findings with severity, a proof (test or command), and a fix recommendation. Include the guard-bypass table.
- For each high or medium finding, a fix on branch `phase/11-security-fixes` with a regression test. Low findings are either fixed or documented in SECURITY.md as accepted risk, with reasoning.

## Acceptance

`make check` and e2e are green; the review doc is committed; PR opened listing the findings and their fixes.
