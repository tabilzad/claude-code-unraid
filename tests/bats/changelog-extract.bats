#!/usr/bin/env bats
# scripts/changelog-extract: sections of a Keep a Changelog file.

load '../helpers/fixtures'

EXTRACT="$REPO_ROOT/scripts/changelog-extract"

setup() {
  CL="$BATS_TEST_TMPDIR/CHANGELOG.md"
  cat >"$CL" <<'CL'
# Changelog

Intro text.

## [Unreleased]

## [0.2.0] - 2026-02-02

### Added

- Two.

## [0.1.0] - 2026-01-01

### Added

- One.
CL
}

@test "--latest skips an empty Unreleased section" {
  run "$EXTRACT" --file "$CL" --latest 1
  [ "$status" -eq 0 ]
  assert_contains "$output" "## [0.2.0] - 2026-02-02"
  assert_contains "$output" "- Two."
  [[ "$output" != *"Unreleased"* ]]
  [[ "$output" != *"0.1.0"* ]]
}

@test "--latest N prints N sections with content, headings included" {
  run "$EXTRACT" --file "$CL" --latest 3
  [ "$status" -eq 0 ]
  assert_contains "$output" "## [0.2.0] - 2026-02-02"
  assert_contains "$output" "## [0.1.0] - 2026-01-01"
  assert_contains "$output" "- One."
  [[ "$output" != *"Unreleased"* ]]
  [[ "$output" != *"Intro text"* ]]
}

@test "--version prints one section's body and fails for an unknown version" {
  run "$EXTRACT" --file "$CL" --version 0.1.0
  [ "$status" -eq 0 ]
  assert_contains "$output" "- One."
  [[ "$output" != *"## ["* ]]
  [[ "$output" != *"Two"* ]]
  run "$EXTRACT" --file "$CL" --version 9.9.9
  [ "$status" -eq 1 ]
}

@test "--unreleased-as renames the first heading" {
  run "$EXTRACT" --file "$CL" --unreleased-as 0.3.0
  [ "$status" -eq 0 ]
  assert_contains "$output" "## [0.3.0]"
}

@test "a non-empty Unreleased section is kept by --latest" {
  cat >"$CL" <<'CL'
## [Unreleased]

### Fixed

- A fix.

## [0.1.0] - 2026-01-01

- One.
CL
  run "$EXTRACT" --file "$CL" --latest 1
  [ "$status" -eq 0 ]
  assert_contains "$output" "## [Unreleased]"
  assert_contains "$output" "- A fix."
  [[ "$output" != *"0.1.0"* ]]
}
