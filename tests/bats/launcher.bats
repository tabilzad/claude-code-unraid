#!/usr/bin/env bats
# /usr/local/bin/claude: environment per mode, the emergency token path, the
# read-only /boot wrapper (command construction; the real remount is on-box
# only), --boot-rw gating and the exit codes.

load '../helpers/fixtures'

setup() {
  make_fakeroot STARTED
  export CCU_TEST_MODE=1
  LAUNCHER="$FAKEROOT/usr/local/bin/claude"
  RUN="$FAKEROOT/run/$PLUGIN"
  LIB="$FAKEROOT/usr/local/lib/$PLUGIN"
  BINARY="$LIB/claude-1.2.3"
  DUMP="$BATS_TEST_TMPDIR/dump"
  export DUMP
  mkdir -p "$LIB" "$RUN"

  # The fake Claude binary records how it was called.
  cat >"$BINARY" <<'EOF'
#!/usr/bin/env bash
{
  printf 'ARGV:'
  for a in "$@"; do printf ' [%s]' "$a"; done
  printf '\n'
  env | LC_ALL=C sort
} >"${DUMP:?}"
exit 0
EOF
  chmod 0755 "$BINARY"
  printf 'version=1.2.3\nsha256=%s\nsource=cache\npath=%s\nerror=\n' "$(sha256sum "$BINARY" | cut -d' ' -f1)" "$BINARY" >"$RUN/binary.state"

  # unshare: record the flags, then run the wrapped command.
  cat >"$FAKEROOT/stubs/bin/unshare" <<'EOF'
#!/usr/bin/env bash
printf 'unshare' >>"${FAKEROOT:?}/calls.log"
for a in "$@"; do printf ' %q' "$a" >>"$FAKEROOT/calls.log"; done
printf '\n' >>"$FAKEROOT/calls.log"
while [ $# -gt 0 ]; do
  if [ "$1" = -- ]; then
    shift
    break
  fi
  shift
done
exec "$@"
EOF
  # mount: record, succeed unless MOUNT_FAIL is set.
  cat >"$FAKEROOT/stubs/bin/mount" <<'EOF'
#!/usr/bin/env bash
printf 'mount' >>"${FAKEROOT:?}/calls.log"
for a in "$@"; do printf ' %q' "$a" >>"$FAKEROOT/calls.log"; done
printf '\n' >>"$FAKEROOT/calls.log"
[ "${MOUNT_FAIL:-0}" = 1 ] && exit 32
exit 0
EOF
  chmod 0755 "$FAKEROOT/stubs/bin/unshare" "$FAKEROOT/stubs/bin/mount"
}

dump_env() { sed -n "s/^$1=//p" "$DUMP"; }
dump_argv() { sed -n 's/^ARGV://p' "$DUMP"; }

@test "fallback mode: config dir in RAM, updates disabled, no token, read-only wrapper" {
  run "$LAUNCHER" --version "two words"
  [ "$status" -eq 0 ]
  [ -f "$DUMP" ]
  [ "$(dump_argv)" = " [--version] [two words]" ]
  [ "$(dump_env CLAUDE_CONFIG_DIR)" = "$RUN/fallback-config" ]
  [ "$(dump_env DISABLE_UPDATES)" = 1 ]
  [ "$(dump_env DISABLE_AUTOUPDATER)" = 1 ]
  [ -z "$(dump_env CLAUDE_CODE_OAUTH_TOKEN)" ]
  assert_file_mode "$RUN/fallback-config" 700
  assert_contains "$(calls unshare)" "--mount --propagation unchanged --"
  assert_contains "$(calls mount)" '-o remount\,bind\,ro /boot'
}

@test "fallback mode with an emergency token passes it through the environment only" {
  local token="sk-ant-oat01-TESTTOKENTESTTOKENTESTTOKEN0123456789"
  printf '%s\n' "$token" >"$FAKEROOT/boot/config/plugins/$PLUGIN/emergency-token"
  run "$LAUNCHER" --print hello
  [ "$status" -eq 0 ]
  [ "$(dump_env CLAUDE_CODE_OAUTH_TOKEN)" = "$token" ]
  assert_not_contains "$(dump_argv)" "$token"
  assert_not_contains "$(cat "$FAKEROOT/calls.log")" "$token"
  assert_not_contains "$(cat "$FAKEROOT/var/log/$PLUGIN/install.log")" "$token"
  assert_contains "$output" "using the emergency token"
}

@test "pool mode: config dir on the data directory, token ignored" {
  printf 'sk-ant-oat01-TESTTOKENTESTTOKENTESTTOKEN0123456789\n' >"$FAKEROOT/boot/config/plugins/$PLUGIN/emergency-token"
  "$SCRIPTS/mode" set pool >/dev/null
  run "$LAUNCHER"
  [ "$status" -eq 0 ]
  [ "$(dump_env CLAUDE_CONFIG_DIR)" = "$FAKEROOT/mnt/user/appdata/$PLUGIN/config" ]
  [ -z "$(dump_env CLAUDE_CODE_OAUTH_TOKEN)" ]
  assert_not_contains "$output" "emergency token"
}

@test "pool mode without its directory degrades to the RAM config for the session" {
  "$SCRIPTS/mode" set pool >/dev/null
  rm -rf "$FAKEROOT/mnt/user/appdata/$PLUGIN"
  run "$LAUNCHER"
  [ "$status" -eq 0 ]
  [ "$(dump_env CLAUDE_CONFIG_DIR)" = "$RUN/fallback-config" ]
  assert_contains "$output" "not available right now"
  [ "$(cat "$RUN/mode")" = pool ]
}

@test "--boot-rw is refused unless the settings allow it" {
  run "$LAUNCHER" --boot-rw
  [ "$status" -eq 80 ]
  [ ! -e "$DUMP" ]
  [ -z "$(calls unshare)" ]
  assert_contains "$output" "ALLOW_BOOT_RW"
}

@test "--boot-rw when allowed: no wrapper, flag stripped, warning and syslog line" {
  printf 'ALLOW_BOOT_RW="yes"\n' >"$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
  run "$LAUNCHER" --boot-rw --continue
  [ "$status" -eq 0 ]
  [ "$(dump_argv)" = " [--continue]" ]
  [ -z "$(calls unshare)" ]
  [ -z "$(calls mount)" ]
  assert_contains "$output" "WRITABLE"
  grep -q 'started with --boot-rw' "$FAKEROOT/var/log/$PLUGIN/install.log"
}

@test "a failed read-only remount refuses to start (79)" {
  export MOUNT_FAIL=1
  run "$LAUNCHER"
  [ "$status" -eq 79 ]
  [ ! -e "$DUMP" ]
  assert_contains "$output" "refusing to start"
}

@test "no verified binary: exit 78 with the recorded error" {
  printf 'version=\nsha256=\nsource=\npath=\nerror=download failed: https://example/claude\n' >"$RUN/binary.state"
  run "$LAUNCHER"
  [ "$status" -eq 78 ]
  assert_contains "$output" "download failed: https://example/claude"
  assert_contains "$output" "claude-unraid doctor"
  rm "$RUN/binary.state"
  run "$LAUNCHER"
  [ "$status" -eq 78 ]
  ln -sf /etc/hostname "$LIB/claude-link"
  printf 'version=1.2.3\nsha256=x\nsource=cache\npath=%s\nerror=\n' "$LIB/claude-link" >"$RUN/binary.state"
  run "$LAUNCHER"
  [ "$status" -eq 78 ]
}

@test "a session started from / or /root gets the workspace hint" {
  mkdir -p "$FAKEROOT/root"
  cd "$FAKEROOT/root"
  run "$LAUNCHER"
  [ "$status" -eq 0 ]
  assert_contains "$output" "claude-unraid work"
  cd "$BATS_TEST_TMPDIR"
  run "$LAUNCHER"
  assert_not_contains "$output" "claude-unraid work"
}

@test "missing plugin files: exit 81" {
  rm "$FAKEROOT/usr/local/emhttp/plugins/$PLUGIN/scripts/lib.sh"
  run "$LAUNCHER"
  [ "$status" -eq 81 ]
}
