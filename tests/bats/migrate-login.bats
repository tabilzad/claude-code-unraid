#!/usr/bin/env bats
# claude-unraid migrate-login: carry a fallback-mode login into the data directory.

load '../helpers/fixtures'

setup() {
  make_fakeroot STARTED
  export CCU_TEST_MODE=1
  CU="$FAKEROOT/usr/local/bin/claude-unraid"
  RUN="$FAKEROOT/run/$PLUGIN"
  DATA="$FAKEROOT/mnt/user/appdata/$PLUGIN"
  mkdir -p "$RUN/fallback-config"
}

@test "refuses without a fallback login" {
  run "$CU" migrate-login
  [ "$status" -eq 1 ]
  assert_contains "$output" "no login found"
}

@test "refuses while in fallback mode" {
  printf '{"claudeAiOauth":{"accessToken":"x"}}' >"$RUN/fallback-config/.credentials.json"
  run "$CU" migrate-login
  [ "$status" -eq 1 ]
  assert_contains "$output" "array is not started"
}

@test "copies only the credentials file, mode 0600, and refuses to overwrite without --force" {
  printf '{"claudeAiOauth":{"accessToken":"x"}}' >"$RUN/fallback-config/.credentials.json"
  printf '{"projects":{}}' >"$RUN/fallback-config/.claude.json"
  "$SCRIPTS/mode" set pool >/dev/null
  run "$CU" migrate-login
  [ "$status" -eq 0 ]
  cmp -s "$RUN/fallback-config/.credentials.json" "$DATA/config/.credentials.json"
  assert_file_mode "$DATA/config/.credentials.json" 600
  [ ! -e "$DATA/config/.claude.json" ]
  assert_not_contains "$output" "accessToken"
  printf '{"claudeAiOauth":{"accessToken":"y"}}' >"$RUN/fallback-config/.credentials.json"
  run "$CU" migrate-login
  [ "$status" -eq 1 ]
  assert_contains "$output" "--force"
  run "$CU" migrate-login --force
  [ "$status" -eq 0 ]
  grep -q '"y"' "$DATA/config/.credentials.json"
}
