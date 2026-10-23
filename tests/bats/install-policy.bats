#!/usr/bin/env bats
# scripts/install-policy: baseline rendering per cfg, user drop-ins, stale
# cleanup, idempotence, and "never write an invalid file".

load '../helpers/fixtures'

JG="$REPO_ROOT/tests/helpers/json-get.php"

setup() {
  make_fakeroot STARTED
  export CCU_TEST_MODE=1
  IP="$SCRIPTS/install-policy"
  POLICY="$FAKEROOT/etc/claude-code/managed-settings.d"
  BASELINE="$POLICY/99-$PLUGIN-baseline.json"
  USERD="$FAKEROOT/boot/config/plugins/$PLUGIN/policy.d"
  CFG="$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
}

get() { php "$JG" "$1" "$2"; }

@test "renders the baseline with every lock, hooks and defaults" {
  run "$IP"
  [ "$status" -eq 0 ]
  [ -f "$BASELINE" ]
  assert_file_mode "$BASELINE" 644
  [ "$(get "$BASELINE" permissions.defaultMode)" = '"default"' ]
  [ "$(get "$BASELINE" permissions.disableBypassPermissionsMode)" = '"disable"' ]
  [ "$(get "$BASELINE" disableAutoMode)" = '"disable"' ]
  [ "$(get "$BASELINE" disableRemoteControl)" = 'true' ]
  [ "$(get "$BASELINE" cleanupPeriodDays)" = '90' ]
  [ "$(get "$BASELINE" env.DISABLE_UPDATES)" = '"1"' ]
  [ "$(get "$BASELINE" env.DISABLE_AUTOUPDATER)" = '"1"' ]
  [ "$(get "$BASELINE" hooks.PreToolUse.0.matcher)" = '"Bash|Write|Edit|MultiEdit|NotebookEdit"' ]
  [ "$(get "$BASELINE" hooks.PreToolUse.0.hooks.0.command)" = "\"/usr/local/emhttp/plugins/$PLUGIN/policy/guard\"" ]
  [ "$(get "$BASELINE" hooks.PreToolUse.0.hooks.0.onFailure)" = '"block"' ]
  [ "$(get "$BASELINE" hooks.PreToolUse.0.hooks.0.timeout)" = '10' ]
  [ "$(get "$BASELINE" hooks.PostToolUse.0.hooks.0.command)" = "\"/usr/local/emhttp/plugins/$PLUGIN/policy/audit\"" ]
  [ "$(get "$BASELINE" hooks.SessionStart.0.hooks.0.command)" = "\"/usr/local/emhttp/plugins/$PLUGIN/policy/session-hook\"" ]
  [ "$(get "$BASELINE" hooks.SessionEnd.0.hooks.0.timeout)" = '10' ]
  [ "$(get "$BASELINE" _comment)" = MISSING ]
  assert_contains "$(get "$BASELINE" permissions.deny)" '"Bash(mkfs*)"'
  assert_contains "$(get "$BASELINE" permissions.allow)" '"Bash(smartctl -a *)"'
  assert_not_contains "$(get "$BASELINE" permissions.allow)" 'docker inspect'
  assert_not_contains "$(get "$BASELINE" permissions.allow)" 'docker logs'
  [ -z "$(find "$POLICY" -name '.99-*')" ]
  [ -z "$(find "$FAKEROOT/run/$PLUGIN" -name 'policy.*')" ]
}

@test "the cfg relaxes only what it is allowed to" {
  printf 'ALLOW_AUTO_MODE="yes"\nREMOTE_CONTROL="yes"\nCLEANUP_DAYS="30"\n' >"$CFG"
  run "$IP"
  [ "$status" -eq 0 ]
  [ "$(get "$BASELINE" disableAutoMode)" = MISSING ]
  [ "$(get "$BASELINE" disableRemoteControl)" = MISSING ]
  [ "$(get "$BASELINE" cleanupPeriodDays)" = '30' ]
  [ "$(get "$BASELINE" permissions.disableBypassPermissionsMode)" = '"disable"' ]
  [ "$(get "$BASELINE" permissions.defaultMode)" = '"default"' ]
  printf 'ALLOW_AUTO_MODE="no"\nREMOTE_CONTROL="no"\n' >"$CFG"
  run "$IP"
  [ "$(get "$BASELINE" disableAutoMode)" = '"disable"' ]
  [ "$(get "$BASELINE" disableRemoteControl)" = 'true' ]
}

@test "an invalid CLEANUP_DAYS keeps the previous baseline and alerts" {
  "$IP" >/dev/null
  local before
  before=$(sha256sum "$BASELINE" | cut -d' ' -f1)
  for bad in 0 abc -5 '1; rm -rf /'; do
    printf 'CLEANUP_DAYS="%s"\n' "$bad" >"$CFG"
    run "$IP"
    [ "$status" -eq 0 ]
    [ "$(sha256sum "$BASELINE" | cut -d' ' -f1)" = "$before" ]
  done
  assert_contains "$(calls notify)" "-i alert"
  rm "$BASELINE"
  printf 'CLEANUP_DAYS="0"\n' >"$CFG"
  run "$IP"
  [ ! -e "$BASELINE" ]
}

@test "valid user drop-ins are installed, invalid ones skipped with a notification" {
  mkdir -p "$USERD"
  printf '{"permissions":{"allow":["Bash(ls *)"]}}\n' >"$USERD/mine.json"
  printf '{not json\n' >"$USERD/bad.json"
  printf '[1,2,3]\n' >"$USERD/list.json"
  printf '{"a":1}\n' >"$USERD/my weird name!.json"
  run "$IP"
  [ "$status" -eq 0 ]
  [ -f "$POLICY/50-user-mine.json" ]
  assert_file_mode "$POLICY/50-user-mine.json" 644
  cmp -s "$USERD/mine.json" "$POLICY/50-user-mine.json"
  [ ! -e "$POLICY/50-user-bad.json" ]
  [ ! -e "$POLICY/50-user-list.json" ]
  [ -f "$POLICY/50-user-my_weird_name_.json" ]
  [ -f "$BASELINE" ]
  local notes
  notes=$(calls notify)
  assert_contains "$notes" "bad.json"
  assert_contains "$notes" "list.json"
  assert_contains "$notes" "-i warning"
  # every installed file is a JSON object (Claude Code would refuse to start otherwise)
  for f in "$POLICY"/*.json; do
    "$SCRIPTS/json-object-check" "$f"
  done
}

@test "stale 50-user files are removed, other files are never touched" {
  mkdir -p "$USERD"
  printf '{"a":1}\n' >"$POLICY/50-user-old.json"
  printf '{"b":2}\n' >"$POLICY/10-other-plugin.json"
  printf '{"c":3}\n' >"$POLICY/60-not-ours.json"
  printf 'junk\n' >"$POLICY/README"
  printf '{"permissions":{"deny":["Bash(x *)"]}}\n' >"$USERD/current.json"
  run "$IP"
  [ "$status" -eq 0 ]
  [ ! -e "$POLICY/50-user-old.json" ]
  [ -f "$POLICY/50-user-current.json" ]
  [ -f "$POLICY/10-other-plugin.json" ]
  [ -f "$POLICY/60-not-ours.json" ]
  [ -f "$POLICY/README" ]
  rm "$USERD/current.json"
  run "$IP"
  [ ! -e "$POLICY/50-user-current.json" ]
  [ -f "$POLICY/10-other-plugin.json" ]
}

@test "running twice changes nothing" {
  mkdir -p "$USERD"
  printf '{"permissions":{"allow":["Bash(ls *)"]}}\n' >"$USERD/mine.json"
  "$IP" >/dev/null
  local before
  before=$(cd "$POLICY" && sha256sum -- * | sort)
  run "$IP"
  [ "$status" -eq 0 ]
  [ "$(cd "$POLICY" && sha256sum -- * | sort)" = "$before" ]
}

@test "hook paths can be redirected for the emulated host" {
  export CCU_HOOK_DIR_OVERRIDE=/opt/hooks
  run "$IP"
  [ "$(get "$BASELINE" hooks.PreToolUse.0.hooks.0.command)" = '"/opt/hooks/guard"' ]
  [ "$(get "$BASELINE" hooks.SessionEnd.0.hooks.0.command)" = '"/opt/hooks/session-hook"' ]
}

@test "the template itself is strict JSON that render-policy accepts" {
  run "$SCRIPTS/json-object-check" "$PLUGIN_SRC/policy/99-baseline.json.in"
  [ "$status" -eq 0 ]
  [ "$(get "$PLUGIN_SRC/policy/99-baseline.json.in" permissions.defaultMode)" = '"default"' ]
}
