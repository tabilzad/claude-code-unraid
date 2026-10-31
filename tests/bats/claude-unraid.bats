#!/usr/bin/env bats
# /usr/local/bin/claude-unraid: status, work, token, verify, doctor.

load '../helpers/fixtures'

setup() {
  make_fakeroot STARTED
  export CCU_TEST_MODE=1
  CU="$FAKEROOT/usr/local/bin/claude-unraid"
  RUN="$FAKEROOT/run/$PLUGIN"
  LIB="$FAKEROOT/usr/local/lib/$PLUGIN"
  FLASH="$FAKEROOT/boot/config/plugins/$PLUGIN"
  BINARY="$LIB/claude-1.2.3"
  mkdir -p "$LIB/bin" "$RUN" "$FAKEROOT/var/lib/pkgtools/packages"
  cat >"$BINARY" <<'EOF'
#!/usr/bin/env bash
printf 'fake claude: %s\n' "$*"
exit 0
EOF
  chmod 0755 "$BINARY"
  printf 'version=1.2.3\nsha256=%s\nsource=cache\npath=%s\nerror=\n' "$(sha256sum "$BINARY" | cut -d' ' -f1)" "$BINARY" >"$RUN/binary.state"
  printf '#!/bin/bash\necho tmux 3.2a\n' >"$LIB/bin/tmux"
  chmod 0755 "$LIB/bin/tmux"
  printf 'pkg=tmux-3.2a-x86_64-1.txz\nversion=3.2a\npath=%s\nsource=cache\nerror=\n' "$LIB/bin/tmux" >"$RUN/tmux.state"
  printf '{}\n' >"$FAKEROOT/etc/claude-code/managed-settings.d/99-$PLUGIN-baseline.json"
  : >"$FAKEROOT/var/lib/pkgtools/packages/$PLUGIN-2026.01.02.3-noarch-1"
  # the wrapper is exercised in launcher.bats; here unshare just runs the command
  cat >"$FAKEROOT/stubs/bin/unshare" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  if [ "$1" = -- ]; then
    shift
    break
  fi
  shift
done
exec "$@"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKEROOT/stubs/bin/mount"
  chmod 0755 "$FAKEROOT/stubs/bin/unshare" "$FAKEROOT/stubs/bin/mount"
}

TOKEN="sk-ant-oat01-TESTTOKENTESTTOKENTESTTOKEN0123456789"

@test "status (text) summarises the plugin" {
  run "$CU" status
  [ "$status" -eq 0 ]
  assert_contains "$output" "plugin:        $PLUGIN 2026.01.02.3"
  assert_contains "$output" "claude code:   1.2.3 (from cache, verified: yes)"
  assert_contains "$output" "tmux:          3.2a"
  assert_contains "$output" "mode:          fallback"
  assert_contains "$output" "data dir:      /mnt/user/appdata/$PLUGIN (on /mnt/user, FUSE)"
  assert_contains "$output" "login:         no"
  assert_contains "$output" "emergency tok: no"
  assert_contains "$output" "flash export:  no"
  assert_contains "$output" "99-$PLUGIN-baseline.json"
}

@test "status --json has the documented shape" {
  run "$CU" status --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" >"$BATS_TEST_TMPDIR/status.json"
  run php "$REPO_ROOT/tests/helpers/status-shape.php" "$BATS_TEST_TMPDIR/status.json"
  [ "$output" = "shape ok" ]
}

@test "status reflects a persisted login and the emergency token" {
  mkdir -p "$FAKEROOT/tmp/$PLUGIN/fallback-config"
  printf '{"claudeAiOauth":{}}' >"$FAKEROOT/tmp/$PLUGIN/fallback-config/.credentials.json"
  printf '%s\n' "$TOKEN" >"$FLASH/emergency-token"
  run "$CU" status
  assert_contains "$output" "login:         yes"
  assert_contains "$output" "emergency tok: yes"
  assert_not_contains "$output" "$TOKEN"
  run "$CU" status --json
  assert_not_contains "$output" "$TOKEN"
}

@test "status reports a degraded binary and flash export" {
  printf 'version=1.2.2\nsha256=%s\nsource=previous\npath=%s\nerror=download failed\n' "$(sha256sum "$BINARY" | cut -d' ' -f1)" "$BINARY" >"$RUN/binary.state"
  write_disks_ini e
  run "$CU" status
  assert_contains "$output" "degraded: download failed"
  assert_contains "$output" "flash export:  yes"
}

@test "work creates a workspace in the current mode's work dir" {
  run --separate-stderr "$CU" work server
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/$PLUGIN/fallback-work/server" ]
  [ -d "$FAKEROOT/tmp/$PLUGIN/fallback-work/server" ]
  assert_contains "$stderr" "fallback mode"
  "$SCRIPTS/mode" set pool >/dev/null
  run --separate-stderr "$CU" work media.tools_2
  [ "$status" -eq 0 ]
  [ "$output" = "/mnt/user/appdata/$PLUGIN/work/media.tools_2" ]
  assert_file_mode "$FAKEROOT/mnt/user/appdata/$PLUGIN/work/media.tools_2" 755
  assert_contains "$stderr" "cd /mnt/user/appdata/$PLUGIN/work/media.tools_2 && claude"
}

@test "work rejects bad names" {
  for name in Bad -x a/b .hidden "$(head -c 49 /dev/zero | tr '\0' a)" ''; do
    run "$CU" work "$name"
    [ "$status" -eq 64 ]
  done
  [ -z "$(ls -A "$FAKEROOT/tmp/$PLUGIN/fallback-work" 2>/dev/null)" ]
}

@test "usage errors name the command and never leak the exit code" {
  # regression: die printed "$*", so every usage error ended in " 64"
  run --separate-stderr "$CU" start
  [ "$status" -eq 64 ]
  [ "$stderr" = "claude-unraid: start needs a workspace name, for example: claude-unraid start server (claude-unraid help lists the commands)" ]
  run --separate-stderr "$CU" work
  [ "$status" -eq 64 ]
  assert_contains "$stderr" "work needs a workspace name"
  run --separate-stderr "$CU" attach ''
  [ "$status" -eq 64 ]
  assert_contains "$stderr" "attach needs a workspace name"
  run --separate-stderr "$CU" start Bad
  [ "$status" -eq 64 ]
  [ "$stderr" = "claude-unraid: bad workspace name 'Bad': 1-48 characters, lowercase letters, digits, '.', '_' or '-', starting with a letter or digit" ]
  run --separate-stderr "$CU" stop $'a\tb'
  [ "$status" -eq 64 ]
  assert_contains "$stderr" "bad workspace name 'a?b'"
  run --separate-stderr "$CU" token bogus
  [ "$status" -eq 64 ]
  [ "$stderr" = "claude-unraid: token needs set, clear or status" ]
}

@test "token set from a pipe stores it with mode 0600 and never prints it" {
  run bash -c "printf '%s\n' '$TOKEN' | '$CU' token set"
  [ "$status" -eq 0 ]
  [ "$(cat "$FLASH/emergency-token")" = "$TOKEN" ]
  assert_file_mode "$FLASH/emergency-token" 600
  assert_not_contains "$output" "$TOKEN"
  assert_not_contains "$(cat "$FAKEROOT/var/log/$PLUGIN/install.log")" "$TOKEN"
  run "$CU" token status
  assert_contains "$output" "present"
  assert_not_contains "$output" "$TOKEN"
  run "$CU" token clear
  [ "$status" -eq 0 ]
  [ ! -e "$FLASH/emergency-token" ]
  run "$CU" token status
  assert_contains "$output" "absent"
}

@test "token set is refused from a terminal without --stdin" {
  command -v script >/dev/null || skip "script(1) not available"
  run script -qec "'$CU' token set" /dev/null
  [ "$status" -ne 0 ]
  assert_contains "$output" "--stdin"
  [ ! -e "$FLASH/emergency-token" ]
}

@test "token set rejects things that are not tokens" {
  run bash -c "printf 'short\n' | '$CU' token set"
  [ "$status" -eq 64 ]
  run bash -c "printf 'has a space in it but is otherwise long enough\n' | '$CU' token set"
  [ "$status" -eq 64 ]
  run bash -c "printf '' | '$CU' token set"
  [ "$status" -eq 64 ]
  [ ! -e "$FLASH/emergency-token" ]
}

@test "token set warns when the flash share is exported" {
  write_disks_ini e
  run bash -c "printf '%s\n' '$TOKEN' | '$CU' token set"
  [ "$status" -eq 0 ]
  assert_contains "$output" "WARNING: the flash share is exported"
}

@test "verify re-hashes the installed binary" {
  run "$CU" verify
  [ "$status" -eq 0 ]
  assert_contains "$output" "OK"
  printf 'tampered' >>"$BINARY"
  run "$CU" verify
  [ "$status" -eq 1 ]
  assert_contains "$output" "FAIL"
  assert_contains "$(calls notify)" "-i alert"
  rm "$RUN/binary.state"
  run "$CU" verify
  [ "$status" -eq 78 ]
}

@test "doctor passes on a healthy install and runs claude doctor through the launcher" {
  run "$CU" doctor
  [ "$status" -eq 0 ]
  assert_contains "$output" "PASS  Claude Code 1.2.3 installed and verified"
  assert_contains "$output" "PASS  tmux 3.2a"
  assert_contains "$output" "WARN  data directory /mnt/user/appdata/$PLUGIN is on /mnt/user (FUSE)"
  assert_contains "$output" "PASS  flash share is not exported"
  assert_contains "$output" "PASS  managed policy baseline present"
  assert_contains "$output" "fake claude: doctor"
  assert_contains "$output" "doctor: 0 failure(s)"
}

@test "doctor fails on a missing baseline and an exported flash with a token" {
  rm "$FAKEROOT/etc/claude-code/managed-settings.d/99-$PLUGIN-baseline.json"
  write_disks_ini eh
  printf '%s\n' "$TOKEN" >"$FLASH/emergency-token"
  run "$CU" doctor
  [ "$status" -eq 1 ]
  assert_contains "$output" "FAIL  managed policy baseline missing"
  assert_contains "$output" "FAIL  the flash share is exported over SMB and an emergency token is stored"
  assert_not_contains "$output" "$TOKEN"
}

@test "doctor warns instead of failing about the data directory while the array is stopped" {
  write_var_ini STOPPED
  write_mountinfo STOPPED
  run "$CU" doctor
  assert_contains "$output" "WARN  data directory"
  assert_not_contains "$output" "FAIL  data directory"
}

@test "session commands need tmux; usage errors" {
  rm "$LIB/bin/tmux"
  run "$CU" start server
  [ "$status" -eq 69 ]
  run "$CU" bogus
  [ "$status" -eq 64 ]
  run "$CU"
  [ "$status" -eq 64 ]
  run "$CU" help
  [ "$status" -eq 0 ]
  assert_contains "$output" "token set"
}

@test "status reports the data directory size and the managed CLAUDE.md" {
  local dd="$FAKEROOT/mnt/user/appdata/$PLUGIN" jg="$REPO_ROOT/tests/helpers/json-get.php"
  mkdir -p "$dd/config/projects/p1" "$dd/work/server"
  head -c 2048 /dev/zero >"$dd/config/projects/p1/t.jsonl"
  head -c 1024 /dev/zero >"$dd/work/server/notes.md"
  run "$CU" status --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" >"$BATS_TEST_TMPDIR/s.json"
  local bytes tbytes
  bytes=$(php "$jg" "$BATS_TEST_TMPDIR/s.json" data_dir.bytes)
  tbytes=$(php "$jg" "$BATS_TEST_TMPDIR/s.json" data_dir.transcripts_bytes)
  [ "$bytes" -ge 3072 ] && [ "$bytes" -lt 3072000 ]
  [ "$tbytes" -ge 2048 ] && [ "$tbytes" -lt 2048000 ]
  [ "$(php "$jg" "$BATS_TEST_TMPDIR/s.json" claude_md)" = false ]
  run "$CU" status
  assert_contains "$output" "data size:     "
  assert_contains "$output" " (transcripts "
  assert_contains "$output" "context file:  none"
  printf '<!-- claude-code-unraid managed CLAUDE.md -->\n# x\n' >"$FAKEROOT/etc/claude-code/CLAUDE.md"
  run "$CU" status --json
  assert_contains "$output" '"claude_md": true'
  run "$CU" status
  assert_contains "$output" "context file:  /etc/claude-code/CLAUDE.md"
  # no data directory: sizes are null, nothing breaks
  rm -rf "$dd"
  run "$CU" status --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" >"$BATS_TEST_TMPDIR/s2.json"
  [ "$(php "$jg" "$BATS_TEST_TMPDIR/s2.json" data_dir.bytes)" = null ]
}

@test "workspaces lists the directories of the current work dir with their session state" {
  local wd="$FAKEROOT/tmp/$PLUGIN/fallback-work" jg="$REPO_ROOT/tests/helpers/json-get.php"
  run "$CU" workspaces
  [ "$status" -eq 0 ]
  assert_contains "$output" "no workspaces in /tmp/$PLUGIN/fallback-work"
  mkdir -p "$wd/server" "$wd/media.tools_2" "$wd/.hidden" "$wd/Bad Name"
  ln -s "$wd/server" "$wd/alias"
  run "$CU" workspaces
  [ "$status" -eq 0 ]
  assert_contains "$output" "WORKSPACE"
  assert_contains "$output" "/tmp/$PLUGIN/fallback-work/server"
  assert_contains "$output" "/tmp/$PLUGIN/fallback-work/media.tools_2"
  assert_not_contains "$output" ".hidden"
  assert_not_contains "$output" "Bad Name"
  assert_not_contains "$output" "alias"
  run "$CU" workspaces --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" >"$BATS_TEST_TMPDIR/w.json"
  [ "$(php "$jg" "$BATS_TEST_TMPDIR/w.json" work_dir)" = "\"/tmp/$PLUGIN/fallback-work\"" ]
  [ "$(php "$jg" "$BATS_TEST_TMPDIR/w.json" workspaces.0)" = "\"media.tools_2|/tmp/$PLUGIN/fallback-work/media.tools_2|$(stat -c %Y "$wd/media.tools_2")|-\"" ]
  [ "$(php "$jg" "$BATS_TEST_TMPDIR/w.json" workspaces.2)" = MISSING ]
  run "$CU" status --json
  assert_contains "$output" "server|/tmp/$PLUGIN/fallback-work/server|$(stat -c %Y "$wd/server")|-"
  run "$CU" status
  assert_contains "$output" "workspaces:    media.tools_2 server"
}
