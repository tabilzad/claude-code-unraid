#!/usr/bin/env bats
# scripts/lint-ca: the Community Applications files must agree with the plg.

load '../helpers/fixtures'

LINT="$REPO_ROOT/scripts/lint-ca"
FIX="$REPO_ROOT/tests/fixtures/render-plg"
WRAPPER="$REPO_ROOT/ca/claude-code-unraid.xml"
PROFILE="$REPO_ROOT/ca_profile.xml"

setup() {
  GOOD="$BATS_TEST_TMPDIR/good.plg"
  "$REPO_ROOT/scripts/render-plg" --version 2026.01.02.3 --plugin-version 0.1.0-beta.1 \
    --txz-name "$PLUGIN-2026.01.02.3-noarch-1.txz" \
    --txz-sha256 1111111111111111111111111111111111111111111111111111111111111111 \
    --lock "$FIX/claude-code.lock" --tmux-lock "$FIX/tmux.lock" --changelog "$FIX/CHANGELOG.md" \
    --out "$GOOD" >/dev/null
}

# mutate SRC DST SED_EXPR: copy SRC to DST with a sed expression applied; fails
# when the expression matched nothing so that a stale test cannot pass.
mutate() {
  sed "$3" "$1" >"$2"
  if cmp -s "$1" "$2"; then
    echo "mutation did not change the file: $3" >&2
    return 1
  fi
}

@test "the repository's CA files agree with the rendered plg" {
  run "$LINT" --plg "$GOOD"
  [ "$status" -eq 0 ]
  assert_contains "$output" "lint-ca: ok (https://github.com/tabilzad/claude-code-unraid/releases/latest/download/claude-code-unraid.plg)"
}

@test "a PluginURL that differs from the plg's pluginURL is rejected" {
  mutate "$WRAPPER" "$BATS_TEST_TMPDIR/w.xml" 's|releases/latest/download/|releases/download/v1.0.0/|'
  run "$LINT" --plg "$GOOD" --wrapper "$BATS_TEST_TMPDIR/w.xml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "PluginURL mismatch"
}

@test "MinVer must equal the plg's min attribute" {
  mutate "$WRAPPER" "$BATS_TEST_TMPDIR/w.xml" 's|<MinVer>7.0.0</MinVer>|<MinVer>6.12.0</MinVer>|'
  run "$LINT" --plg "$GOOD" --wrapper "$BATS_TEST_TMPDIR/w.xml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "MinVer mismatch"
}

@test "Support must equal the plg's support attribute" {
  mutate "$WRAPPER" "$BATS_TEST_TMPDIR/w.xml" 's|<Support>[^<]*</Support>|<Support>https://forums.unraid.net/topic/1-x/</Support>|'
  run "$LINT" --plg "$GOOD" --wrapper "$BATS_TEST_TMPDIR/w.xml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "Support mismatch"
}

@test "an unknown category is rejected" {
  mutate "$WRAPPER" "$BATS_TEST_TMPDIR/w.xml" 's|Tools:Utilities|Tools:Nope|'
  run "$LINT" --plg "$GOOD" --wrapper "$BATS_TEST_TMPDIR/w.xml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "unknown category 'Tools:Nope'"
}

@test "Beta must be true or false" {
  mutate "$WRAPPER" "$BATS_TEST_TMPDIR/w.xml" 's|<Beta>true</Beta>|<Beta>yes</Beta>|'
  run "$LINT" --plg "$GOOD" --wrapper "$BATS_TEST_TMPDIR/w.xml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "Beta must be true or false"
}

@test "the icon must be a PNG file named by the Icon URL" {
  printf 'not a png' >"$BATS_TEST_TMPDIR/claude-code-unraid.png"
  run "$LINT" --plg "$GOOD" --icon "$BATS_TEST_TMPDIR/claude-code-unraid.png"
  [ "$status" -eq 1 ]
  assert_contains "$output" "is not a PNG file"
  cp "$REPO_ROOT/ca/claude-code-unraid.png" "$BATS_TEST_TMPDIR/other.png"
  run "$LINT" --plg "$GOOD" --icon "$BATS_TEST_TMPDIR/other.png"
  [ "$status" -eq 1 ]
  assert_contains "$output" "does not name other.png"
}

@test "starter placeholders are rejected" {
  mutate "$PROFILE" "$BATS_TEST_TMPDIR/p.xml" 's|</CommunityApplications>|<Forum>https://forums.unraid.net/topic/YOUR_SUPPORT_TOPIC</Forum></CommunityApplications>|'
  run "$LINT" --plg "$GOOD" --profile "$BATS_TEST_TMPDIR/p.xml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "placeholder text"
}

@test "malformed XML is rejected" {
  head -n 12 "$WRAPPER" >"$BATS_TEST_TMPDIR/w.xml"
  run "$LINT" --plg "$GOOD" --wrapper "$BATS_TEST_TMPDIR/w.xml"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not well-formed XML"
}
