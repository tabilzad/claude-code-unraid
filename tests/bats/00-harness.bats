#!/usr/bin/env bats
# Proves the test harness itself: the fake root layout, stubs and helpers.

load '../helpers/fixtures'

setup() {
  make_fakeroot STOPPED
}

@test "fake root has the Unraid layout the scripts expect" {
  [ -d "$ROOT/boot/config/plugins/$PLUGIN" ]
  [ -f "$ROOT/var/local/emhttp/var.ini" ]
  [ -f "$ROOT/proc/self/mountinfo" ]
  grep -q '^mdState="STOPPED"' "$ROOT/var/local/emhttp/var.ini"
  run ! grep -q ' /mnt/user ' "$ROOT/proc/self/mountinfo"
}

@test "array state switches the fixtures" {
  write_var_ini STARTED
  write_mountinfo STARTED
  grep -q '^mdState="STARTED"' "$ROOT/var/local/emhttp/var.ini"
  grep -q ' /mnt/user ' "$ROOT/proc/self/mountinfo"
}

@test "stubs record their arguments" {
  logger -t "$PLUGIN" "hello world"
  notify -e "Claude Code" -s "subject" -i warning
  run calls logger
  [ "$output" = "logger -t $PLUGIN hello\\ world" ]
  run calls notify
  assert_contains "$output" "-i warning"
}

@test "ROOT points at the fake root and PATH prefers the stubs" {
  [ "$ROOT" = "$FAKEROOT" ]
  [ "$(command -v logger)" = "$FAKEROOT/stubs/bin/logger" ]
}

@test "list-shell-files finds scripts by extension and shebang" {
  run "$REPO_ROOT/scripts/list-shell-files"
  [ "$status" -eq 0 ]
  assert_contains "$output" "scripts/dev-env"
  assert_contains "$output" "tests/helpers/fixtures.bash"
  assert_contains "$output" "tests/bats/00-harness.bats"
}
