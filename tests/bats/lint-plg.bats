#!/usr/bin/env bats
# scripts/lint-plg: one failing mutation per rule, plus the rendered template passing.

load '../helpers/fixtures'

LINT="$REPO_ROOT/scripts/lint-plg"
FIX="$REPO_ROOT/tests/fixtures/render-plg"
MUTATE="$REPO_ROOT/tests/helpers/plg-mutate.php"

setup() {
  GOOD="$BATS_TEST_TMPDIR/good.plg"
  BAD="$BATS_TEST_TMPDIR/bad.plg"
  "$REPO_ROOT/scripts/render-plg" --version 2026.01.02.3 --plugin-version 0.1.0-beta.1 \
    --txz-name "$PLUGIN-2026.01.02.3-noarch-1.txz" \
    --txz-sha256 1111111111111111111111111111111111111111111111111111111111111111 \
    --lock "$FIX/claude-code.lock" --tmux-lock "$FIX/tmux.lock" --changelog "$FIX/CHANGELOG.md" \
    --out "$GOOD" >/dev/null
}

lint() {
  "$LINT" --lock "$FIX/claude-code.lock" --tmux-lock "$FIX/tmux.lock" "$@"
}

# mutate SED_EXPR: apply a sed expression to the good file, producing BAD.
# Fails loudly when the expression matched nothing, so a stale test cannot
# pass by accident.
mutate() {
  sed "$1" "$GOOD" >"$BAD"
  if cmp -s "$GOOD" "$BAD"; then
    echo "mutation did not change the file: $1" >&2
    return 1
  fi
}

expect_problem() {
  run lint "$BAD"
  [ "$status" -eq 1 ]
  assert_contains "$output" "$1"
}

@test "the rendered template passes" {
  run lint "$GOOD"
  [ "$status" -eq 0 ]
  assert_contains "$output" "ok"
}

@test "the real lock files match the template entities" {
  "$REPO_ROOT/scripts/render-plg" --version 0000.00.00.0-dev --plugin-version 0.0.0-dev \
    --txz-name "$PLUGIN-0000.00.00.0_dev-noarch-1.txz" \
    --txz-sha256 2222222222222222222222222222222222222222222222222222222222222222 \
    --out "$BATS_TEST_TMPDIR/real.plg" >/dev/null
  run "$LINT" "$BATS_TEST_TMPDIR/real.plg"
  [ "$status" -eq 0 ]
}

@test "malformed XML" {
  mutate 's#</PLUGIN>##'
  expect_problem "XML:"
}

@test "URL file without SHA256" {
  mutate '/<SHA256>/d'
  expect_problem "URL file has no SHA256"
}

@test "URL file with MD5" {
  mutate 's#<SHA256>\(.*\)</SHA256>#<MD5>\1</MD5>#'
  expect_problem "MD5 is not accepted"
}

@test "URL file target outside the plugin's flash directory" {
  mutate 's#<FILE Name="&flashDir;/pkg/&txzName;">#<FILE Name="/boot/config/plugins/other/\&txzName;">#'
  expect_problem "target must be under /boot/config/plugins/$PLUGIN/"
}

@test "URL file pointing at the Claude binary" {
  mutate 's#<URL>"&txzURL;"</URL>#<URL>"\&claudeURL;"</URL>#'
  expect_problem "only the plugin's own package may be a URL file"
}

@test "non-https URL" {
  mutate 's#<URL>"&txzURL;"</URL>#<URL>"http://example.com/\&txzName;"</URL>#'
  expect_problem "URL must use https"
}

@test "missing PLUGIN version attribute" {
  mutate '/^        version="&version;"$/d'
  expect_problem "PLUGIN attribute 'version' is missing"
}

@test "missing PLUGIN pluginURL attribute" {
  mutate '/^        pluginURL="&pluginURL;"$/d'
  expect_problem "PLUGIN attribute 'pluginURL' is missing"
}

@test "missing PLUGIN min attribute" {
  mutate '/^        min="&minVer;"$/d'
  expect_problem "PLUGIN attribute 'min' is missing"
}

@test "missing PLUGIN support attribute" {
  mutate '/^        support="&support;"$/d'
  expect_problem "PLUGIN attribute 'support' is missing"
}

@test "malformed PLUGIN version" {
  mutate 's#^<!ENTITY version       "2026.01.02.3">#<!ENTITY version       "2026.1.2">#'
  expect_problem "PLUGIN version must be YYYY.MM.DD.N"
}

@test "undefined entity" {
  mutate 's#^Claude Code &claudeVersion;#Claude Code \&claudeVersion; \&nope;#'
  expect_problem "entity 'nope' is referenced but not defined"
}

@test "unused entity" {
  mutate 's#^<!ENTITY emhttpDir#<!ENTITY unused "x">\n<!ENTITY emhttpDir#'
  expect_problem "entity 'unused' is defined but never used"
}

@test "bare ampersand" {
  mutate 's#^exit 0$#echo a \& b\nexit 0#'
  expect_problem 'bare "&"'
}

@test "INLINE referencing /mnt" {
  mutate 's#^mkdir -p "&flashDir;/pkg"#ls /mnt/user >/dev/null\nmkdir -p "\&flashDir;/pkg"#'
  expect_problem "references /mnt"
}

@test "INLINE that downloads" {
  mutate 's#^run_step install-binary$#wget -q https://example.com/x\nrun_step install-binary#'
  expect_problem "downloads something"
}

@test "INLINE not run by bash" {
  mutate 's#<FILE Run="/bin/bash" Method="remove">#<FILE Run="/bin/sh" Method="remove">#'
  expect_problem "must be run by /bin/bash"
}

@test "LOCAL file" {
  mutate 's#<URL>"&txzURL;"</URL>#<LOCAL>/tmp/x.txz</LOCAL>#'
  expect_problem "LOCAL files are test-only"
}

@test "empty CHANGES" {
  php "$MUTATE" empty-changes "$GOOD" "$BAD"
  expect_problem "CHANGES is empty"
}

@test "pinned Claude sha256 differs from the lock" {
  mutate 's#^<!ENTITY claudeSHA256  "[0-9a-f]*">#<!ENTITY claudeSHA256  "0000000000000000000000000000000000000000000000000000000000000000">#'
  expect_problem "does not match CLAUDE_SHA256"
}

@test "pinned Claude version differs from the lock" {
  mutate 's#^<!ENTITY claudeVersion "2.1.308">#<!ENTITY claudeVersion "2.1.300">#'
  expect_problem "does not match CLAUDE_VERSION"
}

@test "pinned tmux sha256 differs from the lock" {
  mutate 's#^<!ENTITY tmuxSHA256    "[0-9a-f]*">#<!ENTITY tmuxSHA256    "0000000000000000000000000000000000000000000000000000000000000000">#'
  expect_problem "does not match TMUX_SHA256"
}

@test "package name without the plugin version" {
  mutate "s#^<!ENTITY txzName       \"[^\"]*\">#<!ENTITY txzName       \"$PLUGIN-2026.01.02.4-noarch-1.txz\">#"
  expect_problem "does not carry the plugin version"
}

@test "missing remove step" {
  php "$MUTATE" drop-remove "$GOOD" "$BAD"
  expect_problem 'no FILE with Method="remove"'
}

@test "--no-lock skips the cross-check" {
  mutate 's#^<!ENTITY claudeVersion "2.1.308">#<!ENTITY claudeVersion "2.1.300">#'
  run "$LINT" --no-lock "$BAD"
  [ "$status" -eq 0 ]
}
