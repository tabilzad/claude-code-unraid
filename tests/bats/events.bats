#!/usr/bin/env bats
# event/*: timeouts, locking, mode switches, the unsupervised-process report and
# the unmounting_disks backstop (which must only ever touch recorded PIDs).

load '../helpers/fixtures'

setup() {
  make_fakeroot STARTED
  export CCU_TEST_MODE=1
  PDIR="$FAKEROOT/usr/local/emhttp/plugins/$PLUGIN"
  EVENT="$PDIR/event"
  SCR="$PDIR/scripts"
  RUN="$FAKEROOT/run/$PLUGIN"
  DATA="$FAKEROOT/mnt/user/appdata/$PLUGIN"
  LOG="$FAKEROOT/var/log/$PLUGIN/install.log"
  PIDS="$BATS_TEST_TMPDIR/pids"
  : >"$PIDS"
  # A stand-in for claude-unraid: records calls, optionally sleeps or fails.
  cat >"$FAKEROOT/usr/local/bin/claude-unraid" <<'EOF'
#!/usr/bin/env bash
printf 'claude-unraid' >>"${FAKEROOT:?}/calls.log"
for a in "$@"; do printf ' %q' "$a" >>"$FAKEROOT/calls.log"; done
printf '\n' >>"$FAKEROOT/calls.log"
[ -n "${HELPER_SLEEP:-}" ] && sleep "$HELPER_SLEEP"
exit "${HELPER_RC:-0}"
EOF
  chmod 0755 "$FAKEROOT/usr/local/bin/claude-unraid"
}

teardown() {
  local pid
  while read -r pid; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  done <"$PIDS"
  wait 2>/dev/null || true
}

# bg CMD...: start a background process detached from the test's file
# descriptors (bats waits for every holder of its output pipe), remember it
# for teardown, print its PID
bg() {
  "$@" >/dev/null 2>&1 </dev/null &
  local pid=$!
  printf '%s
' "$pid" >>"$PIDS"
  printf '%s' "$pid"
}

@test "disks_mounted switches to pool mode, creates the directories and launches the restore" {
  SECONDS=0
  run "$EVENT/disks_mounted"
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 10 ]
  [ "$(cat "$RUN/mode")" = pool ]
  assert_file_mode "$DATA/config" 700
  assert_file_mode "$DATA/work" 755
  [ -d "$DATA/work/server" ]
  sleep 1
  assert_contains "$(calls claude-unraid)" "claude-unraid restore"
  [ -f "$FAKEROOT/var/log/$PLUGIN/restore.log" ]
  grep -q 'disks_mounted: start' "$LOG"
  grep -q 'disks_mounted: done in' "$LOG"
  grep -q 'pool mode active' "$LOG"
}

@test "disks_mounted stays in fallback mode and never creates a share when DATA_DIR is unusable" {
  printf 'DATA_DIR="/mnt/user/newshare"\n' >"$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  run "$EVENT/disks_mounted"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKEROOT/mnt/user/newshare" ]
  [ "$(cat "$RUN/mode" 2>/dev/null || echo fallback)" = fallback ]
  assert_contains "$(calls notify)" "-i warning"
  grep -q 'not usable' "$LOG"
  [ -z "$(calls claude-unraid)" ]
}

@test "disks_mounted asks before migrating a login made in fallback mode" {
  mkdir -p "$FAKEROOT/tmp/$PLUGIN/fallback-config"
  printf '{"claudeAiOauth":{}}' >"$FAKEROOT/tmp/$PLUGIN/fallback-config/.credentials.json"
  run "$EVENT/disks_mounted"
  [ "$status" -eq 0 ]
  assert_contains "$(calls notify)" 'migrate-login'
  [ ! -e "$DATA/config/.credentials.json" ]
  # once the pool config has a login there is nothing to ask
  : >"$FAKEROOT/calls.log"
  printf '{"claudeAiOauth":{}}' >"$DATA/config/.credentials.json"
  run "$EVENT/disks_mounted"
  [ -z "$(calls notify)" ]
}

@test "disks_mounted honours RESTORE_SESSIONS=no" {
  printf 'RESTORE_SESSIONS="no"\n' >"$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  run "$EVENT/disks_mounted"
  [ "$status" -eq 0 ]
  sleep 1
  [ -z "$(calls claude-unraid)" ]
  [ "$(cat "$RUN/mode")" = pool ]
}

@test "a hanging body is cut off at EVENT_TIMEOUT and the handler still exits 0" {
  printf 'EVENT_TIMEOUT="5"\n' >"$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  printf '#!/bin/bash\nsleep 60\n' >"$SCR/data-dir"
  chmod 0755 "$SCR/data-dir"
  SECONDS=0
  run "$EVENT/disks_mounted"
  [ "$status" -eq 0 ]
  [ "$SECONDS" -ge 4 ]
  [ "$SECONDS" -lt 15 ]
  grep -q 'did not finish within 5s' "$LOG"
  grep -q 'disks_mounted: done in' "$LOG"
}

@test "a handler that cannot get the event lock within 5s gives up, exit 0" {
  mkdir -p "$RUN"
  bg bash -c "exec 9>>'$RUN/event.lock'; flock 9; exec sleep 30" >/dev/null
  sleep 0.5
  SECONDS=0
  run "$EVENT/started"
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 12 ]
  grep -q 'held the lock' "$LOG"
}

@test "stopping with no sessions is quick and switches to fallback" {
  "$SCR/mode" set pool >/dev/null
  SECONDS=0
  run "$EVENT/stopping"
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 5 ]
  [ "$(cat "$RUN/mode")" = fallback ]
  assert_contains "$(calls claude-unraid)" "claude-unraid stop --all --timeout 10"
  grep -q 'fallback mode active' "$LOG"
}

@test "stopping bounds the session stop to 12s even when the helper hangs" {
  export HELPER_SLEEP=60
  SECONDS=0
  run "$EVENT/stopping"
  [ "$status" -eq 0 ]
  [ "$SECONDS" -ge 11 ]
  [ "$SECONDS" -lt 19 ]
  [ "$(cat "$RUN/mode")" = fallback ]
  grep -q 'took longer than 12s' "$LOG"
}

@test "stopping reports unsupervised claude processes under /mnt and nothing else" {
  local exe="/usr/local/lib/$PLUGIN/claude-1.2.3"
  mkproc() { # PID EXE CWD [FD_TARGET]
    mkdir -p "$FAKEROOT/proc/$1/fd"
    ln -s "$2" "$FAKEROOT/proc/$1/exe"
    ln -s "$3" "$FAKEROOT/proc/$1/cwd"
    ln -s /dev/null "$FAKEROOT/proc/$1/fd/0"
    [ -n "${4:-}" ] && ln -s "$4" "$FAKEROOT/proc/$1/fd/3"
    return 0
  }
  mkproc 101 "$exe" "$FAKEROOT/mnt/user/appdata/x"
  mkproc 102 "$exe" /root "$FAKEROOT/mnt/disk1/open.file"
  mkproc 103 "$exe" /root /dev/pts/0
  mkproc 104 /usr/bin/bash "$FAKEROOT/mnt/user"
  mkproc 105 "$exe" "$FAKEROOT/mnt/user/appdata/supervised"
  mkdir -p "$RUN/sessions"
  printf '105\n' >"$RUN/sessions/server.pid"
  run env CCU_PROC_DIR="$FAKEROOT/proc" "$EVENT/stopping"
  [ "$status" -eq 0 ]
  local line
  line=$(grep 'unsupervised claude session' "$LOG")
  assert_contains "$line" "101 (cwd /mnt/user/appdata/x)"
  assert_contains "$line" "102 (cwd /root)"
  assert_not_contains "$line" "103"
  assert_not_contains "$line" "104"
  assert_not_contains "$line" "105"
  assert_contains "$line" "claude-unraid start"
}

@test "stopping stays silent when no unsupervised session uses /mnt" {
  mkdir -p "$FAKEROOT/proc/201/fd"
  ln -s "/usr/local/lib/$PLUGIN/claude-1.2.3" "$FAKEROOT/proc/201/exe"
  ln -s /root "$FAKEROOT/proc/201/cwd"
  run env CCU_PROC_DIR="$FAKEROOT/proc" "$EVENT/stopping"
  [ "$status" -eq 0 ]
  run ! grep -q 'unsupervised claude session' "$LOG"
}

@test "unmounting_disks kills only recorded sessions that still hold files under DATA_DIR" {
  "$SCR/mode" set pool >/dev/null
  mkdir -p "$RUN/sessions"
  local recorded decoy elsewhere
  recorded=$(bg bash -c "cd '$DATA/work' && exec sleep 300")
  decoy=$(bg bash -c "cd '$DATA/work' && exec sleep 300")
  elsewhere=$(bg bash -c "cd /tmp && exec sleep 300")
  printf '%s\n' "$recorded" >"$RUN/sessions/server.pid"
  printf '%s\n' "$elsewhere" >"$RUN/sessions/other.pid"
  printf '424242\n' >"$RUN/sessions/stale.pid"
  sleep 0.3
  run "$EVENT/unmounting_disks"
  [ "$status" -eq 0 ]
  sleep 0.3
  run ! kill -0 "$recorded"
  kill -0 "$decoy"
  kill -0 "$elsewhere"
  grep -q "sending SIGTERM" "$LOG"
  assert_contains "$(grep 'sending SIGTERM' "$LOG")" "$recorded"
  assert_not_contains "$(grep 'sending SIGTERM' "$LOG")" "$decoy"
}

@test "unmounting_disks escalates to SIGKILL after 3s" {
  "$SCR/mode" set pool >/dev/null
  mkdir -p "$RUN/sessions"
  local stubborn
  stubborn=$(bg bash -c "trap '' TERM; cd '$DATA/work' && sleep 300")
  printf '%s\n' "$stubborn" >"$RUN/sessions/server.pid"
  sleep 0.3
  SECONDS=0
  run "$EVENT/unmounting_disks"
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 10 ]
  sleep 0.3
  run ! kill -0 "$stubborn"
  grep -q 'did not exit; killed' "$LOG"
}

@test "unmounting_disks does nothing without a data directory or sessions" {
  write_mountinfo STOPPED
  run "$EVENT/unmounting_disks"
  [ "$status" -eq 0 ]
  run ! grep -q 'SIGTERM' "$LOG"
}

@test "started logs one summary line" {
  "$SCR/mode" set pool >/dev/null
  run "$EVENT/started"
  [ "$status" -eq 0 ]
  grep -q 'array started: mode pool, Claude Code unavailable, tmux unavailable, 0 supervised session(s) running' "$LOG"
}

@test "install while the array is started lands in pool mode; stopped stays fallback" {
  run "$SCR/post-install"
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN/mode")" = pool ]
  assert_contains "$output" "storage mode: pool"
  rm -rf "$RUN"
  write_var_ini STOPPED
  write_mountinfo STOPPED
  run "$SCR/post-install"
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN/mode")" = fallback ]
}

@test "a broken body still leaves the handler at exit 0" {
  chmod 0644 "$SCR/mode"
  run "$EVENT/stopping"
  [ "$status" -eq 0 ]
  grep -q 'could not switch to fallback mode' "$LOG"
}

@test "restore.log and sessions.log are rotated once they pass the size cap" {
  mkdir -p "$FAKEROOT/var/log/$PLUGIN"
  yes x | head -c 600000 >"$FAKEROOT/var/log/$PLUGIN/restore.log"
  run "$EVENT/disks_mounted"
  [ "$status" -eq 0 ]
  sleep 1
  [ -f "$FAKEROOT/var/log/$PLUGIN/restore.log.1" ]
  [ "$(stat -c %s "$FAKEROOT/var/log/$PLUGIN/restore.log")" -lt 1000 ]
  "$SCR/mode" set pool >/dev/null
  yes x | head -c 600000 >"$FAKEROOT/var/log/$PLUGIN/sessions.log"
  run "$EVENT/stopping"
  [ "$status" -eq 0 ]
  [ -f "$FAKEROOT/var/log/$PLUGIN/sessions.log.1" ]
  [ "$(stat -c %s "$FAKEROOT/var/log/$PLUGIN/sessions.log")" -lt 1000 ]
}
