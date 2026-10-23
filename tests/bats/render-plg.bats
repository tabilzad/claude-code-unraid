#!/usr/bin/env bats
# scripts/render-plg: golden-file rendering plus input validation.

load '../helpers/fixtures'

SCRIPT="$REPO_ROOT/scripts/render-plg"
FIX="$REPO_ROOT/tests/fixtures/render-plg"

render() {
  "$SCRIPT" --version 2026.01.02.3 --plugin-version 0.1.0-beta.1 \
    --txz-name "$PLUGIN-2026.01.02.3-noarch-1.txz" \
    --txz-sha256 1111111111111111111111111111111111111111111111111111111111111111 \
    --lock "$FIX/claude-code.lock" --tmux-lock "$FIX/tmux.lock" --changelog "$FIX/CHANGELOG.md" \
    --out "$BATS_TEST_TMPDIR/out.plg" "$@"
}

@test "renders the golden file exactly" {
  run render
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/out.plg" ]
  run diff -u "$FIX/expected.plg" "$BATS_TEST_TMPDIR/out.plg"
  [ "$status" -eq 0 ]
}

@test "the rendered file is well-formed XML after entity expansion" {
  run render
  [ "$status" -eq 0 ]
  run xmllint --noent --noout "$BATS_TEST_TMPDIR/out.plg"
  [ "$status" -eq 0 ]
}

@test "the default package URL points at the GitHub release of the tag" {
  run render
  [ "$status" -eq 0 ]
  grep -q "releases/download/v0.1.0-beta.1/$PLUGIN-2026.01.02.3-noarch-1.txz" "$BATS_TEST_TMPDIR/out.plg"
}

@test "takes the package name and hash from a real file" {
  printf 'pkg' >"$BATS_TEST_TMPDIR/$PLUGIN-2026.01.02.3-noarch-1.txz"
  run "$SCRIPT" --version 2026.01.02.3 --plugin-version 0.1.0 --txz "$BATS_TEST_TMPDIR/$PLUGIN-2026.01.02.3-noarch-1.txz" \
    --lock "$FIX/claude-code.lock" --tmux-lock "$FIX/tmux.lock" --changelog "$FIX/CHANGELOG.md" --out "$BATS_TEST_TMPDIR/o.plg"
  [ "$status" -eq 0 ]
  grep -q "$(sha256sum "$BATS_TEST_TMPDIR/$PLUGIN-2026.01.02.3-noarch-1.txz" | cut -d' ' -f1)" "$BATS_TEST_TMPDIR/o.plg"
}

@test "rejects a package name that does not carry the version" {
  run render --txz-name "$PLUGIN-2026.01.02.4-noarch-1.txz"
  [ "$status" -ne 0 ]
  assert_contains "$output" "does not carry version"
}

@test "rejects malformed versions, hashes and URLs" {
  run render --version 2026.1.2.3
  [ "$status" -ne 0 ]
  run render --plugin-version 'beta'
  [ "$status" -ne 0 ]
  run render --txz-sha256 abc
  [ "$status" -ne 0 ]
  run render --txz-url 'https://example.com/a"b.txz'
  [ "$status" -ne 0 ]
  run render --txz-url 'https://example.com/a&b.txz'
  [ "$status" -ne 0 ]
}

@test "rejects a lock whose URL does not match its version" {
  sed 's#/2.1.308/#/2.1.300/#' "$FIX/claude-code.lock" >"$BATS_TEST_TMPDIR/bad.lock"
  run render --lock "$BATS_TEST_TMPDIR/bad.lock"
  [ "$status" -ne 0 ]
  assert_contains "$output" "CLAUDE_URL"
}

@test "rejects a lock with a malformed sha256 or a missing key" {
  sed 's/^CLAUDE_SHA256=.*/CLAUDE_SHA256=zz/' "$FIX/claude-code.lock" >"$BATS_TEST_TMPDIR/bad.lock"
  run render --lock "$BATS_TEST_TMPDIR/bad.lock"
  [ "$status" -ne 0 ]
  grep -v '^CLAUDE_SIZE=' "$FIX/claude-code.lock" >"$BATS_TEST_TMPDIR/bad2.lock"
  run render --lock "$BATS_TEST_TMPDIR/bad2.lock"
  [ "$status" -ne 0 ]
  assert_contains "$output" "CLAUDE_SIZE missing"
}

@test "fails when a placeholder would survive" {
  sed 's/@TMUX_SIZE@/@TMUX_SIZE@ @NEW_THING@/' "$REPO_ROOT/plugin/$PLUGIN.plg.in" >"$BATS_TEST_TMPDIR/t.plg.in"
  run render --template "$BATS_TEST_TMPDIR/t.plg.in"
  [ "$status" -ne 0 ]
  assert_contains "$output" "unreplaced placeholders: @NEW_THING@"
}

@test "escapes changelog text for XML" {
  printf '# Changelog\n\n## [Unreleased]\n\n- Fixed a < b && c\n' >"$BATS_TEST_TMPDIR/CHANGELOG.md"
  run render --changelog "$BATS_TEST_TMPDIR/CHANGELOG.md"
  [ "$status" -eq 0 ]
  grep -q 'Fixed a &lt; b &amp;&amp; c' "$BATS_TEST_TMPDIR/out.plg"
  run xmllint --noent --noout "$BATS_TEST_TMPDIR/out.plg"
  [ "$status" -eq 0 ]
}
