#!/usr/bin/env bats
# scripts/mode: storage mode switching and the directories each mode needs.

load '../helpers/fixtures'

setup() {
  make_fakeroot STARTED
  export CCU_TEST_MODE=1
  MODE="$SCRIPTS/mode"
  RUN="$FAKEROOT/run/$PLUGIN"
  DATA="$FAKEROOT/mnt/user/appdata/$PLUGIN"
}

teardown() {
  if [ -n "${HOLDER:-}" ]; then
    kill "$HOLDER" 2>/dev/null || true
    wait "$HOLDER" 2>/dev/null || true
  fi
}

@test "defaults to fallback" {
  run "$MODE" get
  [ "$status" -eq 0 ]
  [ "$output" = fallback ]
  run "$MODE" config-dir
  [ "$output" = "/run/$PLUGIN/fallback-config" ]
  run "$MODE" work-dir
  [ "$output" = "/run/$PLUGIN/fallback-work" ]
}

@test "set pool creates the data directories and switches" {
  run "$MODE" set pool
  [ "$status" -eq 0 ]
  [ "$output" = pool ]
  [ "$(cat "$RUN/mode")" = pool ]
  assert_file_mode "$DATA" 700
  assert_file_mode "$DATA/config" 700
  assert_file_mode "$DATA/work" 755
  run "$MODE" config-dir
  [ "$output" = "/mnt/user/appdata/$PLUGIN/config" ]
  run "$MODE" work-dir
  [ "$output" = "/mnt/user/appdata/$PLUGIN/work" ]
}

@test "set fallback creates private RAM directories" {
  run "$MODE" set fallback
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN/mode")" = fallback ]
  assert_file_mode "$RUN/fallback-config" 700
  assert_file_mode "$RUN/fallback-work" 700
}

@test "set pool is refused when the data directory is not usable" {
  write_var_ini STOPPED
  write_mountinfo STOPPED
  run "$MODE" set pool
  [ "$status" -eq 1 ]
  assert_contains "$output" "not mounted"
  run "$MODE" get
  [ "$output" = fallback ]
}

@test "set is refused while a supervised session is alive, unless forced" {
  mkdir -p "$RUN/sessions"
  sleep 60 &
  HOLDER=$!
  printf '%s\n' "$HOLDER" >"$RUN/sessions/server.pid"
  run "$MODE" set pool
  [ "$status" -eq 76 ]
  assert_contains "$output" "1 supervised session(s) running"
  run "$MODE" get
  [ "$output" = fallback ]
  run "$MODE" set pool --force
  [ "$status" -eq 0 ]
  run "$MODE" get
  [ "$output" = pool ]
}

@test "a stale pid file does not count as a live session" {
  mkdir -p "$RUN/sessions"
  printf '999999\n' >"$RUN/sessions/old.pid"
  printf 'garbage\n' >"$RUN/sessions/junk.pid"
  run "$MODE" set pool
  [ "$status" -eq 0 ]
}

@test "config-dir falls back to RAM when pool mode's directory disappears" {
  "$MODE" set pool >/dev/null
  rm -rf "$DATA"
  run "$MODE" config-dir
  [ "$output" = "/run/$PLUGIN/fallback-config" ]
}

@test "ensure-dirs recreates what the current mode needs" {
  "$MODE" set pool >/dev/null
  rm -rf "$DATA/config" "$DATA/work"
  run "$MODE" ensure-dirs
  [ "$status" -eq 0 ]
  [ -d "$DATA/config" ] && [ -d "$DATA/work" ]
}

@test "usage errors" {
  run "$MODE" set sideways
  [ "$status" -eq 64 ]
  run "$MODE" set pool --bogus
  [ "$status" -eq 64 ]
  run "$MODE" frobnicate
  [ "$status" -eq 64 ]
}
