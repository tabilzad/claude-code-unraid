#!/usr/bin/env bats
# policy/session-hook: the registry written from SessionStart/SessionEnd.

load '../helpers/fixtures'

HOOK="$PLUGIN_SRC/policy/session-hook"
JG="$REPO_ROOT/tests/helpers/json-get.php"

setup() {
  make_fakeroot STARTED
  export CCU_TEST_MODE=1
  DATA="$FAKEROOT/mnt/user/appdata/$PLUGIN"
  mkdir -p "$DATA/config" "$DATA/work/server"
  export CLAUDE_CONFIG_DIR="$DATA/config"
  REG="$DATA/sessions.json"
}

# payload EVENT ID [EXTRA_JSON_FIELDS]
payload() {
  local event=$1 id=$2 extra=${3:-}
  printf '{"session_id":"%s","transcript_path":"%s/config/projects/x/%s.jsonl","cwd":"%s/work/server","hook_event_name":"%s"%s}' \
    "$id" "$DATA" "$id" "$DATA" "$event" "${extra:+,$extra}"
}
hook() { php "$HOOK"; }
get() { php "$JG" "$REG" "$1"; }

@test "SessionStart creates an entry with the workspace derived from the cwd" {
  run bash -c "$(declare -f payload); DATA='$DATA'; payload SessionStart sess-1 '\"source\":\"startup\"' | php '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$REG" ]
  assert_file_mode "$REG" 600
  [ "$(get version)" = 1 ]
  [ "$(get sessions.0.session_id)" = '"sess-1"' ]
  [ "$(get sessions.0.workspace)" = '"server"' ]
  [ "$(get sessions.0.cwd)" = "\"$DATA/work/server\"" ]
  [ "$(get sessions.0.supervised)" = false ]
  [ "$(get sessions.0.remote_control)" = false ]
  [ "$(get sessions.0.ended_at)" = null ]
  [ "$(get sessions.0.source)" = '"startup"' ]
  [ "$(get sessions.0.restore)" = false ]
}

@test "supervised and remote flags come from the supervisor's environment" {
  payload SessionStart sess-2 '"source":"startup"' | CLAUDE_CODE_UNRAID_SUPERVISED=1 CLAUDE_CODE_UNRAID_REMOTE_CONTROL=1 hook
  [ "$(get sessions.0.supervised)" = true ]
  [ "$(get sessions.0.remote_control)" = true ]
}

@test "SessionEnd records the reason; resume reopens; clear starts a new entry" {
  payload SessionStart sess-3 '"source":"startup"' | hook
  payload SessionEnd sess-3 '"reason":"prompt_input_exit"' | hook
  [ "$(get sessions.0.end_reason)" = '"prompt_input_exit"' ]
  [ "$(get sessions.0.ended_at)" != null ]
  payload SessionStart sess-3 '"source":"resume"' | hook
  [ "$(get sessions.0.ended_at)" = null ]
  [ "$(get sessions.0.source)" = '"resume"' ]
  payload SessionStart sess-4 '"source":"clear"' | hook
  [ "$(get sessions.1.session_id)" = '"sess-4"' ]
  [ "$(get sessions.1.source)" = '"clear"' ]
}

@test "an end for an unknown session still leaves a trace" {
  payload SessionEnd sess-x '"reason":"other"' | hook
  [ "$(get sessions.0.session_id)" = '"sess-x"' ]
  [ "$(get sessions.0.end_reason)" = '"other"' ]
}

@test "concurrent hooks never lose entries or corrupt the file" {
  local i
  for i in $(seq 1 20); do
    payload SessionStart "sess-$i" '"source":"startup"' | hook &
  done
  wait
  [ "$("$SCRIPTS/registry" list "$REG" | wc -l)" -eq 20 ]
  [ -z "$(find "$DATA" -name '.sessions.*.tmp')" ]
}

@test "a corrupt registry is moved aside and a fresh one started" {
  printf '{not json' >"$REG"
  payload SessionStart sess-5 '"source":"startup"' | hook
  [ "$(get sessions.0.session_id)" = '"sess-5"' ]
  [ -n "$(find "$DATA" -name 'sessions.json.corrupt-*')" ]
  printf '[1,2,3]' >"$REG"
  payload SessionStart sess-6 '"source":"startup"' | hook
  [ "$(get sessions.0.session_id)" = '"sess-6"' ]
}

@test "fallback mode writes the registry next to the RAM config" {
  mkdir -p "$FAKEROOT/tmp/$PLUGIN/fallback-config"
  export CLAUDE_CONFIG_DIR="$FAKEROOT/tmp/$PLUGIN/fallback-config"
  payload SessionStart sess-7 '"source":"startup"' | hook
  [ -f "$FAKEROOT/tmp/$PLUGIN/sessions.json" ]
  [ ! -e "$REG" ]
  [ "$(php "$JG" "$FAKEROOT/tmp/$PLUGIN/sessions.json" sessions.0.workspace)" = null ]
}

@test "old ended entries are pruned by CLEANUP_DAYS, flagged ones are kept" {
  printf 'CLEANUP_DAYS="30"\n' >"$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  cat >"$REG" <<'EOF'
{"version":1,"sessions":[
 {"session_id":"old-ended","cwd":"/x","workspace":null,"started_at":"2020-01-01T00:00:00Z","updated_at":"2020-01-01T00:00:00Z","ended_at":"2020-01-02T00:00:00Z","end_reason":"other","supervised":false,"remote_control":false,"source":"startup","restore":false},
 {"session_id":"old-flagged","cwd":"/x","workspace":"w","started_at":"2020-01-01T00:00:00Z","updated_at":"2020-01-01T00:00:00Z","ended_at":"2020-01-02T00:00:00Z","end_reason":"other","supervised":true,"remote_control":false,"source":"startup","restore":true},
 {"session_id":"old-live","cwd":"/x","workspace":"w","started_at":"2020-01-01T00:00:00Z","updated_at":"2020-01-01T00:00:00Z","ended_at":null,"end_reason":null,"supervised":true,"remote_control":false,"source":"startup","restore":false}
]}
EOF
  payload SessionStart sess-8 '"source":"startup"' | hook
  run bash -c "'$SCRIPTS/registry' list '$REG' | cut -f2"
  [ "$output" = $'old-flagged\nold-live\nsess-8' ]
}

@test "the hook never fails: bad input, odd ids, unwritable registry" {
  run bash -c "printf 'nope' | php '$HOOK'"
  [ "$status" -eq 0 ]
  run bash -c "printf '' | php '$HOOK'"
  [ "$status" -eq 0 ]
  run bash -c "printf '{\"hook_event_name\":\"SessionStart\",\"session_id\":\"../../etc\",\"cwd\":\"/\"}' | php '$HOOK'"
  [ "$status" -eq 0 ]
  [ ! -e "$REG" ]
  mkdir "$REG" # a directory where the file should be: the rename must fail cleanly
  run bash -c "$(declare -f payload); DATA='$DATA'; payload SessionStart sess-9 '\"source\":\"startup\"' | php '$HOOK'"
  [ "$status" -eq 0 ]
  grep -q 'could not update the session registry' "$FAKEROOT/var/log/$PLUGIN/install.log"
}
