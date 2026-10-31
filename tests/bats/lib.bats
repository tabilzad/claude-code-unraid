#!/usr/bin/env bats
# scripts/lib.sh: config parsing, ini parsing, atomic writes, locks, hashing,
# bounded logging and the cache helpers.

load '../helpers/fixtures'

setup() {
  make_fakeroot
  export CCU_TEST_MODE=1
  # shellcheck source=src/usr/local/emhttp/plugins/claude-code-unraid/scripts/lib.sh
  . "$SCRIPTS/lib.sh"
}

@test "paths honour ROOT" {
  [ "$FLASH_DIR" = "$FAKEROOT/boot/config/plugins/$PLUGIN" ]
  [ "$RUN_DIR" = "$FAKEROOT/run/$PLUGIN" ]
  [ "$POLICY_DIR" = "$FAKEROOT/etc/claude-code/managed-settings.d" ]
}

@test "cfg_get: user cfg overrides default.cfg, default.cfg overrides the fallback" {
  [ "$(cfg_get RESTORE_SESSIONS)" = "yes" ]
  printf 'RESTORE_SESSIONS="no"\n' >"$CFG_FILE"
  [ "$(cfg_get RESTORE_SESSIONS)" = "no" ]
  [ "$(cfg_get NOT_A_KEY fallback)" = "fallback" ]
  [ "$(cfg_get DATA_DIR)" = "" ]
}

@test "cfg_get: unquoted values, CRLF, last occurrence wins, never sourced" {
  printf 'MAX_RESTORE=7\r\nMAX_RESTORE="8"\nDATA_DIR="/mnt/cache/appdata/x"; touch %s/pwned\n' "$FAKEROOT" >"$CFG_FILE"
  [ "$(cfg_get MAX_RESTORE)" = "8" ]
  [ "$(cfg_get DATA_DIR)" = '/mnt/cache/appdata/x' ]
  [ ! -e "$FAKEROOT/pwned" ]
}

@test "cfg_get: values with control characters fall back to the default" {
  printf 'DATA_DIR="/mnt/x\ty"\n' >"$CFG_FILE"
  [ "$(cfg_get DATA_DIR)" = "" ]
  printf 'EVENT_TIMEOUT="30"\n' >"$CFG_FILE"
  [ "$(cfg_get EVENT_TIMEOUT 20)" = "30" ]
}

@test "cfg_get: rejects malformed keys" {
  [ "$(cfg_get 'DATA_DIR; rm' d)" = "d" ]
  [ "$(cfg_get lowercase d)" = "d" ]
}

@test "cfg_bool normalises" {
  printf 'ALLOW_BOOT_RW="YES"\nREMOTE_CONTROL="1"\nALLOW_AUTO_MODE="maybe"\n' >"$CFG_FILE"
  [ "$(cfg_bool ALLOW_BOOT_RW)" = yes ]
  [ "$(cfg_bool REMOTE_CONTROL)" = yes ]
  [ "$(cfg_bool ALLOW_AUTO_MODE)" = no ]
  [ "$(cfg_bool RESTORE_SESSIONS)" = yes ]
}

@test "ini_get and ini_section_get read emhttp ini files" {
  [ "$(array_state)" = STOPPED ]
  write_var_ini STARTED
  [ "$(array_state)" = STARTED ]
  [ "$(ini_section_get "$DISKS_INI" flash export)" = "-" ]
  write_disks_ini eh
  [ "$(ini_section_get "$DISKS_INI" flash export)" = "eh" ]
  [ "$(ini_section_get "$DISKS_INI" cache export)" = "-" ]
  run ini_section_get "$DISKS_INI" nope export
  [ "$status" -ne 0 ]
  rm "$VAR_INI"
  [ "$(array_state)" = UNKNOWN ]
}

@test "atomic_write sets the mode and leaves no temp files" {
  printf 'hello\n' | atomic_write "$FAKEROOT/run/x/state" 0600
  [ "$(cat "$FAKEROOT/run/x/state")" = hello ]
  assert_file_mode "$FAKEROOT/run/x/state" 600
  printf 'again\n' | atomic_write "$FAKEROOT/run/x/state" 0644
  [ "$(cat "$FAKEROOT/run/x/state")" = again ]
  assert_file_mode "$FAKEROOT/run/x/state" 644
  [ -z "$(find "$FAKEROOT/run/x" -name '.state.*')" ]
}

@test "state_write and state_get round trip" {
  state_write "$RUN_DIR/t.state" "version=1.2.3" "error=" "path=/x y"
  [ "$(state_get "$RUN_DIR/t.state" version)" = 1.2.3 ]
  [ "$(state_get "$RUN_DIR/t.state" path)" = "/x y" ]
  [ -z "$(state_get "$RUN_DIR/t.state" error)" ]
  run state_get "$RUN_DIR/missing" version
  [ "$status" -ne 0 ]
}

@test "with_lock runs the command and times out when the lock is held" {
  run with_lock "$RUN_DIR/t.lock" 2 echo held
  [ "$status" -eq 0 ]
  [ "$output" = held ]
  # hold the lock from another process
  (
    exec 8>>"$RUN_DIR/t.lock"
    flock 8
    sleep 4
  ) &
  holder=$!
  sleep 0.5
  run with_lock "$RUN_DIR/t.lock" 1 echo nope
  [ "$status" -eq 75 ]
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "run_with_timeout kills a hanging command" {
  run run_with_timeout 1 sleep 10
  [ "$status" -eq 124 ]
}

@test "sha256_eq compares case-insensitively and fails on missing files" {
  printf 'abc' >"$FAKEROOT/f"
  local sha
  sha=$(sha256_of "$FAKEROOT/f")
  sha256_eq "$FAKEROOT/f" "$sha"
  sha256_eq "$FAKEROOT/f" "${sha^^}"
  run sha256_eq "$FAKEROOT/f" "0000000000000000000000000000000000000000000000000000000000000000"
  [ "$status" -ne 0 ]
  run sha256_eq "$FAKEROOT/missing" "$sha"
  [ "$status" -ne 0 ]
}

@test "log writes a bounded file and calls logger" {
  CCU_SCRIPT_NAME=unit log info "hello there"
  grep -q '\[info\] unit: hello there' "$INSTALL_LOG"
  run calls logger
  assert_contains "$output" 'unit:\ hello\ there'
  head -c $((LOG_MAX_BYTES + 10)) /dev/zero | tr '\0' 'x' >"$INSTALL_LOG"
  log info "after rotation"
  [ -f "$INSTALL_LOG.1" ]
  [ "$(stat -c %s "$INSTALL_LOG")" -lt 1000 ]
  grep -q 'after rotation' "$INSTALL_LOG"
}

@test "notify calls the Unraid notify script with the event name" {
  notify warning "Subject" "Description"
  run calls notify
  assert_contains "$output" "-e Claude\\ Code -s Subject -d Description -i warning"
  rm "$NOTIFY_BIN"
  notify alert "x" "y" # no script: silent no-op
}

@test "url_allowed: exact match in production, local URLs with the same basename in test mode" {
  url_allowed "https://downloads.claude.ai/claude-code-releases/1.2.3/linux-x64/claude" "https://downloads.claude.ai/claude-code-releases/1.2.3/linux-x64/claude"
  url_allowed "file:///tmp/bucket/1.2.3/linux-x64/claude" "https://downloads.claude.ai/claude-code-releases/1.2.3/linux-x64/claude"
  run url_allowed "file:///tmp/bucket/1.2.3/linux-x64/other" "https://downloads.claude.ai/claude-code-releases/1.2.3/linux-x64/claude"
  [ "$status" -ne 0 ]
  run url_allowed "https://evil.example/claude" "https://downloads.claude.ai/claude-code-releases/1.2.3/linux-x64/claude"
  [ "$status" -ne 0 ]
  CCU_TEST_MODE=0
  test_mode=0
  run url_allowed "file:///tmp/bucket/1.2.3/linux-x64/claude" "https://downloads.claude.ai/claude-code-releases/1.2.3/linux-x64/claude"
  [ "$status" -ne 0 ]
}

@test "free_kb override is honoured only in test mode" {
  CCU_FAKE_FREE_KB=42
  [ "$(free_kb "$FAKEROOT")" = 42 ]
  test_mode=0
  [[ "$(free_kb "$FAKEROOT")" =~ ^[0-9]+$ ]]
  [ "$(free_kb "$FAKEROOT")" != 42 ]
}

@test "prune_cache keeps the current and the newest previous entry with sidecars" {
  mkdir -p "$FLASH_DIR/bin"
  for v in 1.0.0 1.1.0 1.2.0 1.3.0; do
    printf '%s' "$v" >"$FLASH_DIR/bin/claude-$v"
    printf 'x  claude-%s\n' "$v" >"$FLASH_DIR/bin/claude-$v.sha256"
  done
  touch -d '2026-01-01' "$FLASH_DIR/bin/claude-1.0.0"
  touch -d '2026-01-03' "$FLASH_DIR/bin/claude-1.1.0"
  touch -d '2026-01-02' "$FLASH_DIR/bin/claude-1.2.0"
  touch -d '2026-01-04' "$FLASH_DIR/bin/claude-1.3.0"
  prune_cache "$FLASH_DIR/bin" claude- claude-1.3.0
  run ls "$FLASH_DIR/bin"
  [ "$output" = $'claude-1.1.0\nclaude-1.1.0.sha256\nclaude-1.3.0\nclaude-1.3.0.sha256' ]
}

@test "fetch_verified: cache hit, corrupt cache, download, sha mismatch, low space" {
  local bucket="$BATS_TEST_TMPDIR/bucket" sha
  mkdir -p "$bucket"
  printf 'payload' >"$bucket/thing"
  sha=$(sha256_of "$bucket/thing")
  local cache="$FLASH_DIR/bin/thing"
  fetch_verified thing "file://$bucket/thing" "$sha" 7 "$cache"
  [ "$FETCH_SOURCE" = download ]
  [ -f "$cache.sha256" ]
  fetch_verified thing "file://$bucket/missing" "$sha" 7 "$cache"
  [ "$FETCH_SOURCE" = cache ]
  printf 'corrupt' >"$cache"
  fetch_verified thing "file://$bucket/thing" "$sha" 7 "$cache"
  [ "$FETCH_SOURCE" = download ]
  [ "$(cat "$cache")" = payload ]
  rm -f "$cache" "$cache.sha256"
  run fetch_verified thing "file://$bucket/thing" "0000000000000000000000000000000000000000000000000000000000000000" 7 "$cache"
  [ "$status" -ne 0 ]
  [ ! -e "$cache" ]
  CCU_FAKE_FREE_KB=1 run fetch_verified thing "file://$bucket/thing" "$sha" 1048576 "$cache"
  [ "$status" -ne 0 ]
  [ ! -e "$cache" ]
  [ -z "$(find "$RUN_DIR" "$FLASH_DIR/bin" -maxdepth 1 -name '*dl.*')" ]
}

@test "fetch_verified refuses a symlink in the cache slot" {
  local bucket="$BATS_TEST_TMPDIR/bucket" sha
  mkdir -p "$bucket" "$FLASH_DIR/bin"
  printf 'payload' >"$bucket/thing"
  sha=$(sha256_of "$bucket/thing")
  ln -s /etc/hostname "$FLASH_DIR/bin/thing"
  run fetch_verified thing "file://$bucket/thing" "$sha" 7 "$FLASH_DIR/bin/thing"
  [ "$status" -ne 0 ]
  [ -L "$FLASH_DIR/bin/thing" ]
}

@test "install_ram_copy verifies, sets the mode and refuses non-regular targets" {
  printf 'bin' >"$FAKEROOT/src"
  local sha
  sha=$(sha256_of "$FAKEROOT/src")
  install_ram_copy "$FAKEROOT/src" "$LIB_DIR/claude-1" "$sha" 0755
  assert_file_mode "$LIB_DIR/claude-1" 755
  [ -z "$(find "$LIB_DIR" -name '.claude-1.*')" ]
  ln -s /etc/hostname "$LIB_DIR/claude-2"
  run install_ram_copy "$FAKEROOT/src" "$LIB_DIR/claude-2" "$sha" 0755
  [ "$status" -ne 0 ]
  [ -L "$LIB_DIR/claude-2" ]
  run install_ram_copy "$FAKEROOT/src" "$LIB_DIR/claude-3" "0000000000000000000000000000000000000000000000000000000000000000" 0755
  [ "$status" -ne 0 ]
  [ ! -e "$LIB_DIR/claude-3" ]
}

@test "fetch_verified downloads next to the cache, never under /run, and reports the downloader's error" {
  # Unraid mounts /run as a 32 MiB tmpfs: the first beta failed there with a
  # 292 MB binary. The temporary file must live in the cache directory.
  mkdir -p "$FLASH_DIR/bin"
  touch "$FLASH_DIR/bin/.dl.stale"
  cat >"$FAKEROOT/stubs/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl' >>"${FAKEROOT:?}/calls.log"
for a in "$@"; do printf ' %q' "$a" >>"$FAKEROOT/calls.log"; done
printf '\n' >>"$FAKEROOT/calls.log"
echo 'curl: (23) Failure writing output to destination' >&2
exit 23
STUB
  chmod 0755 "$FAKEROOT/stubs/bin/curl"
  local rc=0
  fetch_verified thing "https://downloads.claude.ai/claude-code-releases/9.9.9/linux-x64/claude" \
    0000000000000000000000000000000000000000000000000000000000000000 7 "$FLASH_DIR/bin/thing" || rc=$?
  [ "$rc" -ne 0 ]
  assert_contains "$(calls curl)" "--output $FLASH_DIR/bin/.dl."
  assert_contains "$FETCH_ERROR" "download failed: https://downloads.claude.ai/claude-code-releases/9.9.9/linux-x64/claude (exit 23: curl: (23) Failure writing output to destination)"
  [ ! -e "$FLASH_DIR/bin/.dl.stale" ]
  [ -z "$(find "$FLASH_DIR/bin" "$RUN_DIR" -maxdepth 1 -name '*dl.*' 2>/dev/null)" ]
  [ ! -e "$FLASH_DIR/bin/thing" ]
}
