#!/usr/bin/env bats
# scripts/post-install: mode handling and the install summary.

load '../helpers/fixtures'

SCRIPT_UNDER_TEST="$SCRIPTS/post-install"

setup() {
  make_fakeroot
  export CCU_TEST_MODE=1
  RUN="$FAKEROOT/run/$PLUGIN"
}

@test "first run creates the mode file as fallback" {
  run "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN/mode")" = fallback ]
  assert_contains "$output" "storage mode: fallback"
  assert_contains "$output" "Claude Code NOT available"
  assert_contains "$output" "tmux NOT available"
  assert_contains "$output" "Not affiliated"
}

@test "an existing mode is kept (update while the array runs)" {
  mkdir -p "$RUN"
  printf 'pool\n' >"$RUN/mode"
  run "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ "$(cat "$RUN/mode")" = pool ]
  assert_contains "$output" "storage mode: pool"
}

@test "the summary reflects the binary, tmux and package states" {
  mkdir -p "$RUN" "$FAKEROOT/var/lib/pkgtools/packages"
  printf 'version=2.1.308\nsha256=abc\nsource=cache\npath=/usr/local/lib/x\nerror=\n' >"$RUN/binary.state"
  printf 'pkg=tmux-3.2a-x86_64-1.txz\nversion=3.2a\npath=/x\nsource=download\nerror=\n' >"$RUN/tmux.state"
  : >"$FAKEROOT/var/lib/pkgtools/packages/$PLUGIN-2026.01.02.3-noarch-1"
  run "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  assert_contains "$output" "$PLUGIN 2026.01.02.3"
  assert_contains "$output" "Claude Code 2.1.308 (from cache)"
  assert_contains "$output" "tmux 3.2a"
  grep -q 'Claude Code 2.1.308' "$FAKEROOT/var/log/$PLUGIN/install.log"
}

@test "a degraded binary state is spelled out" {
  mkdir -p "$RUN"
  printf 'version=2.1.300\nsha256=abc\nsource=previous\npath=/x\nerror=download failed: https://example\n' >"$RUN/binary.state"
  run "$SCRIPT_UNDER_TEST"
  assert_contains "$output" "Claude Code 2.1.300 (from previous), degraded: download failed"
}
