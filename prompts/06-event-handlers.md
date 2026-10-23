# Phase 06: Array lifecycle event handlers

Read `CLAUDE.md` (invariants 2, 5, 9), `docs/SPEC.md` sections 6 and 8, and the event documentation at the top of `unraid/webgui`'s `sbin/emhttp_event`. Note that **`stopping_array` fires after disks are unmounted**, so it's useless for cleanup. Use plan mode.

## Tasks

1. Put the event handlers in `src/usr/local/emhttp/plugins/PLUGIN/event/` as executable files: `disks_mounted`, `started`, `stopping` and `unmounting_disks`. Each one:
   - sources `scripts/lib.sh`
   - runs its body under `timeout "${EVENT_TIMEOUT:-20}"`, with an inner `flock -w 5 /run/PLUGIN/event.lock`
   - logs a start line and an end line with the duration
   - **always exits 0**, because emhttp ignores failures but a non-zero exit is confusing in logs
2. **`disks_mounted`:**
   - Resolve and validate DATA_DIR; on failure, notify and stay in fallback.
   - Create `config/`, `work/` and `work/server/` with 0700/0755 as appropriate.
   - If the fallback config contains a login made during fallback and the pool config has none, notify the user with the exact `claude-unraid` command to migrate. Don't auto-migrate.
   - `mode set pool --force`.
   - Launch the session restore **in the background** with `setsid` and `nohup`, logging to `/var/log/PLUGIN/restore.log`. The restore itself is a stub until phase 08 and must exit cleanly.
3. **`stopping`:**
   - Stop supervised sessions: phase 08 implements `claude-unraid stop --all --timeout 10`; until then, a stub. Must complete within 12 s.
   - `mode set fallback --force`.
   - Find unsupervised `claude` processes with a cwd or open files under `/mnt`: scan `/proc/*/cwd` and `/proc/*/fd`, bounded. Log their PIDs and a hint. **Don't kill them.**
4. **`unmounting_disks`:** a backstop. Only processes recorded as supervised by us, and still holding files under DATA_DIR, get SIGTERM, then after 3 s SIGKILL. Never kill anything else.
5. **`started`:** a one-line status summary to syslog.
6. Make sure plugin **install while the array is already started** works: phase 04's `post-install` keeps the mode, and here `post-install` must also run the `disks_mounted` logic once, inline and bounded, if the array is started (determine that from `/var/local/emhttp/var.ini` `mdState`).

## Tests

bats with the fake root and fake `/proc` entries:
- each handler respects the timeout (simulate a hanging stop)
- lock contention
- `disks_mounted` with an invalid DATA_DIR stays in fallback
- `disks_mounted` never creates a share
- `stopping` with no sessions is instant
- the `unmounting_disks` backstop kills only recorded PIDs; put a decoy PID in the test
- install-while-started path

## Acceptance

- `make check` is green.
- On-box test steps for me:
  - array stop/start cycle with `claude` open in a terminal (cwd under DATA_DIR): what should happen, and what the syslog shows
  - reboot with array autostart on and off
  - confirm the array stop never stalls more than about 15 s because of the plugin
- PR from `phase/06-event-handlers`.
