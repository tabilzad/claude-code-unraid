#!/usr/bin/env bats
# scripts/remove: full and partial installs, what goes and what stays.

load '../helpers/fixtures'

SCRIPT_UNDER_TEST="$SCRIPTS/remove"

setup() {
  make_fakeroot
  export CCU_TEST_MODE=1
  make_stub removepkg
  FLASH="$FAKEROOT/boot/config/plugins/$PLUGIN"
  POLICY="$FAKEROOT/etc/claude-code/managed-settings.d"
}

populate_full_install() {
  mkdir -p "$FAKEROOT/usr/local/lib/$PLUGIN/bin" "$FAKEROOT/run/$PLUGIN" "$FAKEROOT/var/log/$PLUGIN" \
    "$FAKEROOT/usr/local/emhttp/plugins/$PLUGIN/scripts" "$FAKEROOT/var/lib/pkgtools/packages" \
    "$FLASH/bin" "$FLASH/pkg" "$FLASH/policy.d" "$POLICY"
  printf 'bin' >"$FAKEROOT/usr/local/lib/$PLUGIN/claude-1.2.3"
  printf 'tmux' >"$FAKEROOT/usr/local/lib/$PLUGIN/bin/tmux"
  printf 'fallback\n' >"$FAKEROOT/run/$PLUGIN/mode"
  printf 'log\n' >"$FAKEROOT/var/log/$PLUGIN/install.log"
  printf '#!/bin/bash\n' >"$FAKEROOT/usr/local/emhttp/plugins/$PLUGIN/scripts/x"
  printf '#!/bin/bash\n' >"$FAKEROOT/usr/local/bin/claude"
  printf '#!/bin/bash\n' >"$FAKEROOT/usr/local/bin/claude-unraid"
  printf '{}' >"$POLICY/99-$PLUGIN-baseline.json"
  printf '{}' >"$POLICY/50-user-mine.json"
  printf '{}' >"$POLICY/10-other-plugin.json"
  printf '<!-- claude-code-unraid managed CLAUDE.md -->\n# x\n' >"$FAKEROOT/etc/claude-code/CLAUDE.md"
  printf 'pkg' >"$FLASH/bin/claude-1.2.3"
  printf 'pkg' >"$FLASH/pkg/$PLUGIN-2026.01.02.3-noarch-1.txz"
  printf 'DATA_DIR="%s"
' "/mnt/cache/appdata/$PLUGIN" >"$FLASH/$PLUGIN.cfg"
  printf '{}' >"$FLASH/policy.d/mine.json"
  printf 'tok' >"$FLASH/emergency-token"
  printf 'files\n' >"$FAKEROOT/var/lib/pkgtools/packages/$PLUGIN-2026.01.02.3-noarch-1"
}

@test "a full install is removed except for user data" {
  populate_full_install
  run "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKEROOT/usr/local/lib/$PLUGIN" ]
  [ ! -e "$FAKEROOT/run/$PLUGIN" ]
  [ ! -e "$FAKEROOT/var/log/$PLUGIN" ]
  [ ! -e "$FAKEROOT/usr/local/emhttp/plugins/$PLUGIN" ]
  [ ! -e "$FAKEROOT/usr/local/bin/claude" ]
  [ ! -e "$FAKEROOT/usr/local/bin/claude-unraid" ]
  [ ! -e "$POLICY/99-$PLUGIN-baseline.json" ]
  [ ! -e "$POLICY/50-user-mine.json" ]
  [ -e "$POLICY/10-other-plugin.json" ]
  [ ! -e "$FAKEROOT/etc/claude-code/CLAUDE.md" ]
  [ ! -e "$FLASH/bin" ]
  [ ! -e "$FLASH/pkg" ]
  [ -f "$FLASH/$PLUGIN.cfg" ]
  [ -f "$FLASH/policy.d/mine.json" ]
  [ -f "$FLASH/emergency-token" ]
  assert_contains "$(calls removepkg)" "$PLUGIN-2026.01.02.3-noarch-1"
  assert_contains "$output" "/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  assert_contains "$output" "policy.d"
  assert_contains "$output" "emergency-token"
  assert_contains "$output" "/mnt/cache/appdata/$PLUGIN"
}

@test "a CLAUDE.md that is not ours stays" {
  populate_full_install
  printf '# mine\n' >"$FAKEROOT/etc/claude-code/CLAUDE.md"
  run "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKEROOT/etc/claude-code/CLAUDE.md")" = "# mine" ]
}

@test "the policy directory is removed only when nothing else is left in it" {
  populate_full_install
  rm "$POLICY/10-other-plugin.json"
  run "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ ! -e "$POLICY" ]
  [ ! -e "$FAKEROOT/etc/claude-code" ]
}

@test "a partial install (nothing but the package scripts) removes cleanly" {
  run "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  assert_contains "$output" "removed"
  [ -z "$(calls removepkg)" ]
  assert_contains "$output" "<appdata>/$PLUGIN"
}

@test "the session helper is asked to stop sessions first when present" {
  populate_full_install
  cat >"$FAKEROOT/usr/local/bin/claude-unraid" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"${FAKEROOT_MARK:?}"
EOF
  chmod 0755 "$FAKEROOT/usr/local/bin/claude-unraid"
  FAKEROOT_MARK="$BATS_TEST_TMPDIR/helper-args" run "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/helper-args")" = "stop --all --timeout 10" ]
}
