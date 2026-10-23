#!/usr/bin/env bats
# claude-unraid start/stop/attach/list/restore against a fake tmux and a fake
# launcher (tests/helpers/fake-tmux.bash, fake-claude.bash).

load '../helpers/fixtures'

setup() {
  make_fakeroot STARTED
  export CCU_TEST_MODE=1
  CU="$FAKEROOT/usr/local/bin/claude-unraid"
  RUN="$FAKEROOT/run/$PLUGIN"
  LIB="$FAKEROOT/usr/local/lib/$PLUGIN"
  DATA="$FAKEROOT/mnt/user/appdata/$PLUGIN"
  REG="$DATA/sessions.json"
  LOG="$FAKEROOT/var/log/$PLUGIN/install.log"
  mkdir -p "$LIB/bin" "$RUN"
  install -m 0755 "$REPO_ROOT/tests/helpers/fake-tmux.bash" "$LIB/bin/tmux"
  install -m 0755 "$REPO_ROOT/tests/helpers/fake-claude.bash" "$FAKEROOT/usr/local/bin/claude"
  printf 'pkg=tmux-3.2a-x86_64-1.txz\nversion=3.2a\npath=%s\nsource=cache\nerror=\n' "$LIB/bin/tmux" >"$RUN/tmux.state"
  export FAKE_TMUX_STATE="$RUN/fake-tmux"
  export FAKE_CLAUDE_DUMP="$BATS_TEST_TMPDIR/dump"
  export CCU_RESTORE_GRACE=1
  "$SCRIPTS/mode" set pool >/dev/null
}

teardown() {
  local d
  for d in "$FAKE_TMUX_STATE"/*/; do
    [ -f "$d/pid" ] && kill -9 "$(cat "$d/pid")" 2>/dev/null
  done
  return 0
}

# seed_registry: a live supervised entry for server, a resume-failing one for
# media, an unsupervised one, an ended one and one whose workspace is gone
seed_registry() {
  mkdir -p "$DATA/work/server" "$DATA/work/media" "$DATA/work/old"
  cat >"$REG" <<EOF
{"version":1,"sessions":[
 {"session_id":"sid-server-1","cwd":"/mnt/user/appdata/$PLUGIN/work/server","workspace":"server","started_at":"2026-01-01T10:00:00Z","updated_at":"2026-01-01T10:00:00Z","ended_at":null,"end_reason":null,"supervised":true,"remote_control":false,"source":"startup","restore":false},
 {"session_id":"sid-server-0","cwd":"/mnt/user/appdata/$PLUGIN/work/server","workspace":"server","started_at":"2026-01-01T09:00:00Z","updated_at":"2026-01-01T09:00:00Z","ended_at":null,"end_reason":null,"supervised":true,"remote_control":false,"source":"startup","restore":false},
 {"session_id":"fail-media-1","cwd":"/mnt/user/appdata/$PLUGIN/work/media","workspace":"media","started_at":"2026-01-01T11:00:00Z","updated_at":"2026-01-01T11:00:00Z","ended_at":"2026-01-01T12:00:00Z","end_reason":"other","supervised":true,"remote_control":true,"source":"startup","restore":true},
 {"session_id":"sid-unsup","cwd":"/mnt/user/appdata/$PLUGIN/work/server","workspace":"server","started_at":"2026-01-01T12:00:00Z","updated_at":"2026-01-01T12:00:00Z","ended_at":null,"end_reason":null,"supervised":false,"remote_control":false,"source":"startup","restore":false},
 {"session_id":"sid-ended","cwd":"/mnt/user/appdata/$PLUGIN/work/old","workspace":"old","started_at":"2026-01-01T08:00:00Z","updated_at":"2026-01-01T08:30:00Z","ended_at":"2026-01-01T08:30:00Z","end_reason":"prompt_input_exit","supervised":true,"remote_control":false,"source":"startup","restore":false},
 {"session_id":"sid-gone","cwd":"/mnt/user/appdata/$PLUGIN/work/gone","workspace":"gone","started_at":"2026-01-01T13:00:00Z","updated_at":"2026-01-01T13:00:00Z","ended_at":null,"end_reason":null,"supervised":true,"remote_control":false,"source":"startup","restore":false}
]}
EOF
}

args_of() { cat "$FAKE_CLAUDE_DUMP/$PLUGIN-$1.args"; }
env_of() { cat "$FAKE_CLAUDE_DUMP/$PLUGIN-$1.env"; }
registry_field() { php "$REPO_ROOT/tests/helpers/json-get.php" "$REG" "sessions.$1.$2"; }

@test "start launches the launcher in the workspace inside tmux and records the pid" {
  run "$CU" start server
  [ "$status" -eq 0 ]
  assert_contains "$output" "session server started in /mnt/user/appdata/$PLUGIN/work/server"
  assert_contains "$output" "claude-unraid attach server"
  [ -d "$DATA/work/server" ]
  sleep 0.5
  [ "$(args_of server)" = "" ]
  [ "$(env_of server)" = "CLAUDE_CODE_UNRAID_SUPERVISED=1" ]
  [ -f "$RUN/sessions/server.pid" ]
  [ "$(cat "$RUN/sessions/server.pid")" = "$(cat "$FAKE_TMUX_STATE/$PLUGIN-server/pid")" ]
  kill -0 "$(cat "$RUN/sessions/server.pid")"
  grep -q '^workspace=server$' "$RUN/sessions/server.info"
  run "$CU" list
  assert_contains "$output" "server"
  assert_contains "$output" "running"
  run "$CU" start server
  [ "$status" -eq 0 ]
  assert_contains "$output" "already running"
}

@test "start --remote-control needs the setting and passes the flag through" {
  run "$CU" start media --remote-control
  [ "$status" -eq 77 ]
  [ ! -e "$FAKE_TMUX_STATE/$PLUGIN-media" ]
  printf 'REMOTE_CONTROL="yes"\n' >"$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  run "$CU" start media --remote-control
  [ "$status" -eq 0 ]
  sleep 0.5
  [ "$(args_of media)" = "--remote-control media" ]
  assert_contains "$(env_of media)" "CLAUDE_CODE_UNRAID_REMOTE_CONTROL=1"
  assert_contains "$(env_of media)" "CLAUDE_CODE_UNRAID_SUPERVISED=1"
}

@test "start refuses bad names and needs tmux" {
  run "$CU" start 'Bad Name'
  [ "$status" -eq 64 ]
  rm "$LIB/bin/tmux"
  run "$CU" start server
  [ "$status" -eq 69 ]
  assert_contains "$output" "claude-unraid doctor"
}

@test "stop sends /exit, records the end in the registry and cleans up" {
  seed_registry
  "$CU" start server >/dev/null
  sleep 0.3
  SECONDS=0
  run "$CU" stop server
  [ "$status" -eq 0 ]
  [ "$SECONDS" -lt 6 ]
  assert_contains "$output" "stopped 1 session(s): server"
  grep -q '^/exit$' "$FAKE_TMUX_STATE/$PLUGIN-server/keys"
  [ ! -e "$RUN/sessions/server.pid" ]
  [ ! -e "$RUN/sessions/server.info" ]
  run "$CU" list
  assert_not_contains "$output" "running"
  # the live supervised entry for server is now ended, not flagged
  [ "$(registry_field 0 end_reason)" = '"stopped"' ]
  [ "$(registry_field 0 restore)" = 'false' ]
  run ! grep -q 'did not exit' "$LOG"
}

@test "stop --mark-restore flags the live entry instead of ending it" {
  seed_registry
  "$CU" start server >/dev/null
  sleep 0.3
  run "$CU" stop --all --timeout 4 --mark-restore
  [ "$status" -eq 0 ]
  [ "$(registry_field 0 restore)" = 'true' ]
  [ "$(registry_field 0 ended_at)" = 'null' ]
}

@test "a session that ignores /exit and SIGTERM is killed within the timeout" {
  export FAKE_CLAUDE_STUBBORN=1
  "$CU" start server >/dev/null
  sleep 0.3
  local pid
  pid=$(cat "$RUN/sessions/server.pid")
  SECONDS=0
  run "$CU" stop server --timeout 3
  [ "$status" -eq 0 ]
  [ "$SECONDS" -ge 2 ]
  [ "$SECONDS" -lt 8 ]
  sleep 0.3
  run ! kill -0 "$pid"
  grep -q 'did not exit within 3s; killed' "$LOG"
  [ ! -e "$FAKE_TMUX_STATE/$PLUGIN-server" ]
}

@test "stop with nothing running and stop of a stopped workspace" {
  run "$CU" stop --all
  [ "$status" -eq 0 ]
  assert_contains "$output" "no supervised sessions running"
  run "$CU" stop server
  [ "$status" -eq 0 ]
  assert_contains "$output" "server is not running"
  run "$CU" stop
  [ "$status" -eq 64 ]
}

@test "attach needs a running session" {
  run "$CU" attach server
  [ "$status" -eq 1 ]
  "$CU" start server >/dev/null
  run "$CU" attach server
  [ "$status" -eq 0 ]
  [ "$output" = "attached $PLUGIN-server" ]
}

@test "restore --dry-run selects flagged or live supervised entries, newest per workspace, with an existing cwd" {
  seed_registry
  run "$CU" restore --dry-run
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = $'fail-media-1\tmedia\t/mnt/user/appdata/'"$PLUGIN"$'/work/media\t2026-01-01T11:00:00Z\tyes' ]
  [ "${lines[1]}" = $'sid-server-1\tserver\t/mnt/user/appdata/'"$PLUGIN"$'/work/server\t2026-01-01T10:00:00Z\tno' ]
  printf 'MAX_RESTORE="1"\n' >"$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  run "$CU" restore --dry-run
  [ "${#lines[@]}" -eq 1 ]
  assert_contains "${lines[0]}" "fail-media-1"
}

@test "restore resumes sessions, starts fresh when a resume fails, and clears the flags" {
  seed_registry
  run "$CU" restore
  [ "$status" -eq 0 ]
  assert_contains "$output" "restore: 1 resumed, 1 started fresh, 0 failed"
  sleep 0.5
  [ "$(args_of server)" = "--resume sid-server-1" ]
  [ "$(args_of media)" = "" ]
  run "$CU" list
  assert_contains "$output" "server"
  assert_contains "$output" "media"
  [ "$(registry_field 2 restore)" = 'false' ]
  grep -q 'resuming fail-media-1 in media failed; starting a fresh session there' "$LOG"
  assert_contains "$(calls notify)" "-i normal"
  # a second restore finds nothing new and leaves the running sessions alone
  run "$CU" restore
  assert_contains "$output" "0 resumed, 0 started fresh"
}

@test "restore respects REMOTE_CONTROL when bringing back a remote session" {
  seed_registry
  printf 'REMOTE_CONTROL="yes"\n' >"$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  "$CU" restore >/dev/null
  sleep 0.5
  [ "$(args_of media)" = "--remote-control media" ]
  [ "$(args_of server)" = "--resume sid-server-1" ]
}

@test "restore is a no-op when disabled, in fallback mode, or without tmux" {
  seed_registry
  printf 'RESTORE_SESSIONS="no"\n' >"$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  run "$CU" restore
  assert_contains "$output" "disabled"
  [ ! -e "$FAKE_TMUX_STATE/$PLUGIN-server" ]
  rm "$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  "$SCRIPTS/mode" set fallback >/dev/null
  run "$CU" restore
  assert_contains "$output" "only runs in pool mode"
  "$SCRIPTS/mode" set pool >/dev/null
  rm "$LIB/bin/tmux"
  run "$CU" restore
  [ "$status" -eq 0 ]
  assert_contains "$(calls notify)" "tmux"
}

@test "status lists supervised sessions" {
  "$CU" start server >/dev/null
  run "$CU" status
  assert_contains "$output" "sessions:      server (running)"
  run "$CU" status --json
  assert_contains "$output" '"server|running|'
}

@test "mode set refuses to switch under a running session" {
  "$CU" start server >/dev/null
  sleep 0.3
  run "$SCRIPTS/mode" set fallback
  [ "$status" -eq 76 ]
}
