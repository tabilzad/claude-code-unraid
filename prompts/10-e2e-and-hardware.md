# Phase 10: End-to-end harness and on-box test plan

Read `CLAUDE.md`, all of `docs/SPEC.md`, and `docs/SPIKE.md`.

Goal: a repeatable end-to-end test in CI on an emulated host, plus a scripted on-hardware test run that I execute and you analyze.

## Tasks

1. **Emulated host (`tests/e2e/`):**
   - A container based on a pinned Slackware image (by digest) with PHP, util-linux and bash.
   - Provide: Lime's `plugin` script (already vendored in phase 03), a fake `/boot` on a tmpfs, fake `/mnt/cache/appdata` and `/mnt/user`, `var.ini`, a stub `notify`, and a stub `claude` binary, plus a fake release bucket served locally whose manifest pins the stub's sha256 (test mode only).
   - Script these scenarios end to end:
     1. fresh install with the array stopped (fallback mode)
     2. `disks_mounted` (pool mode, dirs created)
     3. supervised session start (stub claude sleeps)
     4. `stopping` (session stopped, fallback)
     5. "reboot": wipe the RAM dirs, re-run `plugin install` from `/boot/config/plugins`; the cache is used and nothing downloaded
     6. `disks_mounted` again (restore picks up the session)
     7. plugin update to a new version with a new stub binary sha256 (previous version kept and pruned to 2)
     8. corrupted flash cache plus network down (degraded, previous version used, plg not in `plugins-error`)
     9. remove (RAM side gone; cfg and DATA_DIR kept)
   - Run it in CI as a separate job; it may need `--privileged` for unshare. If so, isolate it and explain.
2. **On-hardware test plan (`docs/TESTING.md`):** a numbered checklist I run on the test server, with exact commands and expected results. Cover:
   - fresh install from the release plg URL
   - login in pool mode
   - reboot with autostart on
   - reboot with autostart off (fallback, emergency token if enabled)
   - array stop/start with a live session
   - `smartctl -a` and `zpool iostat` workflows through Claude
   - a guard block or ask demo
   - `/boot` ro and `--boot-rw`
   - Remote Control on and off
   - plugin update
   - Unraid OS update (plugin survives)
   - plugin removal
   - the parity-array box and a ZFS-pool box, if I have both
3. **`scripts/collect-diagnostics`:** a script for the test box that gathers plugin state for me to paste back:
   - `claude-unraid status --json`
   - the last 200 lines of the plugin logs
   - the event lines from syslog
   - managed-settings file names (not contents of user drop-ins)
   - `ls -la` of the plugin dirs

   It redacts tokens, emails and serial numbers.

## Acceptance

- The e2e job is green in CI. Paste the scenario summary.
- `docs/TESTING.md` is complete. Then **stop and wait**: I'll run the hardware checklist and paste the diagnostics. Fix what fails, adding a regression test for each bug, until the checklist passes on hardware.
- PR from `phase/10-e2e`.
