#!/usr/bin/env bats
# scripts/install-binary against a file:// release bucket (test mode).

load '../helpers/fixtures'

SCRIPT_UNDER_TEST="$SCRIPTS/install-binary"

setup() {
  make_fakeroot
  export CCU_TEST_MODE=1
  BUCKET="$BATS_TEST_TMPDIR/bucket"
  make_release 1.2.3
  BIN="$FAKEROOT/boot/config/plugins/$PLUGIN/bin"
  LIB="$FAKEROOT/usr/local/lib/$PLUGIN"
  STATE="$FAKEROOT/run/$PLUGIN/binary.state"
}

make_release() {
  mkdir -p "$BUCKET/$1/linux-x64"
  printf '#!/bin/bash\necho "fake claude %s"\n' "$1" >"$BUCKET/$1/linux-x64/claude"
}
rel_sha() { sha256sum "$BUCKET/$1/linux-x64/claude" | cut -d' ' -f1; }
rel_size() { stat -c %s "$BUCKET/$1/linux-x64/claude"; }

# install VERSION [URL] [SHA]
install() {
  local v=$1 url=${2:-file://$BUCKET/$1/linux-x64/claude} sha=${3:-$(rel_sha "$1")}
  CLAUDE_VERSION="$v" CLAUDE_SHA256="$sha" CLAUDE_URL="$url" CLAUDE_SIZE="$(rel_size "$v" 2>/dev/null || echo 40)" "$SCRIPT_UNDER_TEST"
}
state() { sed -n "s/^$1=//p" "$STATE"; }

@test "fresh install: downloads, verifies, caches on flash and copies to RAM" {
  run install 1.2.3
  [ "$status" -eq 0 ]
  [ "$(state version)" = 1.2.3 ]
  [ "$(state source)" = download ]
  [ "$(state sha256)" = "$(rel_sha 1.2.3)" ]
  [ -z "$(state error)" ]
  [ "$(state path)" = "$LIB/claude-1.2.3" ]
  assert_file_mode "$LIB/claude-1.2.3" 755
  [ "$("$LIB/claude-1.2.3")" = "fake claude 1.2.3" ]
  cmp -s "$BIN/claude-1.2.3" "$BUCKET/1.2.3/linux-x64/claude"
  grep -q "^$(rel_sha 1.2.3)  claude-1.2.3$" "$BIN/claude-1.2.3.sha256"
  [ -z "$(calls notify)" ]
  [ -z "$(find "$FAKEROOT/run/$PLUGIN" -name 'dl.*')" ]
}

@test "reinstall with a valid cache does not download" {
  install 1.2.3 >/dev/null
  rm -rf "$LIB"
  run install 1.2.3 "file://$BUCKET/does-not-exist/linux-x64/claude"
  [ "$status" -eq 0 ]
  [ "$(state source)" = cache ]
  [ "$(state version)" = 1.2.3 ]
  [ -x "$LIB/claude-1.2.3" ]
}

@test "a corrupt cache is discarded and re-downloaded" {
  install 1.2.3 >/dev/null
  printf 'corrupt' >"$BIN/claude-1.2.3"
  rm -rf "$LIB"
  run install 1.2.3
  [ "$status" -eq 0 ]
  [ "$(state source)" = download ]
  cmp -s "$BIN/claude-1.2.3" "$BUCKET/1.2.3/linux-x64/claude"
  grep -q 'fails verification' "$FAKEROOT/var/log/$PLUGIN/install.log"
}

@test "download failure with a previous version falls back to it (degraded, warning)" {
  install 1.2.3 >/dev/null
  rm -rf "$LIB"
  make_release 1.2.4
  run install 1.2.4 "file://$BUCKET/does-not-exist/linux-x64/claude"
  [ "$status" -eq 0 ]
  [ "$(state version)" = 1.2.3 ]
  [ "$(state source)" = previous ]
  assert_contains "$(state error)" "download failed"
  [ -x "$LIB/claude-1.2.3" ]
  [ ! -e "$LIB/claude-1.2.4" ]
  assert_contains "$(calls notify)" "-i warning"
  assert_contains "$(calls notify)" "1.2.3"
}

@test "download failure without a previous version records an alert and exits 0" {
  run install 1.2.3 "file://$BUCKET/does-not-exist/linux-x64/claude"
  [ "$status" -eq 0 ]
  [ -z "$(state version)" ]
  assert_contains "$(state error)" "download failed"
  [ -z "$(ls -A "$LIB" 2>/dev/null)" ]
  assert_contains "$(calls notify)" "-i alert"
}

@test "a sha256 mismatch is rejected and nothing lands on flash" {
  run install 1.2.3 "" "0000000000000000000000000000000000000000000000000000000000000000"
  [ "$status" -eq 0 ]
  assert_contains "$(state error)" "sha256 mismatch"
  [ ! -e "$BIN/claude-1.2.3" ]
  [ ! -e "$BIN/claude-1.2.3.sha256" ]
  [ ! -e "$LIB/claude-1.2.3" ]
  assert_contains "$(calls notify)" "-i alert"
}

@test "a symlink planted at the RAM target is refused" {
  mkdir -p "$LIB"
  ln -s "$FAKEROOT/etc/unraid-version" "$LIB/claude-1.2.3"
  run install 1.2.3
  [ "$status" -eq 0 ]
  assert_contains "$(state error)" "not a regular file"
  [ -L "$LIB/claude-1.2.3" ]
  [ "$(readlink "$LIB/claude-1.2.3")" = "$FAKEROOT/etc/unraid-version" ]
  grep -q '^version="7.0.0"' "$FAKEROOT/etc/unraid-version"
  [ -z "$(state version)" ]
}

@test "low flash space is refused before downloading" {
  export CCU_FAKE_FREE_KB=0
  run install 1.2.3
  [ "$status" -eq 0 ]
  assert_contains "$(state error)" "not enough free space"
  [ ! -e "$BIN/claude-1.2.3" ]
  [ ! -e "$LIB/claude-1.2.3" ]
}

@test "the flash cache keeps exactly the current and the newest previous version" {
  mkdir -p "$BIN"
  for v in 1.0.0 1.1.0 1.2.0; do
    printf 'old %s' "$v" >"$BIN/claude-$v"
    printf '%s  claude-%s\n' "$(sha256sum "$BIN/claude-$v" | cut -d' ' -f1)" "$v" >"$BIN/claude-$v.sha256"
  done
  touch -d '2026-01-01' "$BIN/claude-1.0.0"
  touch -d '2026-01-02' "$BIN/claude-1.1.0"
  touch -d '2026-01-03' "$BIN/claude-1.2.0"
  run install 1.2.3
  [ "$status" -eq 0 ]
  run ls "$BIN"
  [ "$output" = $'claude-1.2.0\nclaude-1.2.0.sha256\nclaude-1.2.3\nclaude-1.2.3.sha256' ]
}

@test "stale RAM copies of other versions are removed" {
  mkdir -p "$LIB"
  printf 'old' >"$LIB/claude-0.9.0"
  install 1.2.3 >/dev/null
  run ls "$LIB"
  [ "$output" = "claude-1.2.3" ]
}

@test "a previous version is only used when its sidecar verifies" {
  mkdir -p "$BIN"
  printf 'old 1.1.0' >"$BIN/claude-1.1.0"
  printf '%s  claude-1.1.0\n' "0000000000000000000000000000000000000000000000000000000000000000" >"$BIN/claude-1.1.0.sha256"
  printf 'old 1.0.0' >"$BIN/claude-1.0.0" # no sidecar at all
  run install 1.2.3 "file://$BUCKET/does-not-exist/linux-x64/claude"
  [ "$status" -eq 0 ]
  [ -z "$(state version)" ]
  [ ! -e "$LIB/claude-1.1.0" ]
  [ ! -e "$LIB/claude-1.0.0" ]
}

@test "invalid parameters are refused without touching the network" {
  run env CLAUDE_VERSION=1.2 CLAUDE_SHA256="$(rel_sha 1.2.3)" CLAUDE_URL="file://$BUCKET/1.2.3/linux-x64/claude" "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  assert_contains "$(state error)" "CLAUDE_VERSION"
  run env CLAUDE_VERSION=1.2.3 CLAUDE_SHA256=abc CLAUDE_URL="file://$BUCKET/1.2.3/linux-x64/claude" "$SCRIPT_UNDER_TEST"
  assert_contains "$(state error)" "CLAUDE_SHA256"
  run env CLAUDE_VERSION=1.2.3 CLAUDE_SHA256="$(rel_sha 1.2.3)" CLAUDE_URL="https://evil.example/claude" "$SCRIPT_UNDER_TEST"
  assert_contains "$(state error)" "CLAUDE_URL"
  run env CLAUDE_VERSION=1.2.3 CLAUDE_SHA256="$(rel_sha 1.2.3)" CLAUDE_URL="file://$BUCKET/1.2.3/linux-x64/claude" CLAUDE_SIZE=big "$SCRIPT_UNDER_TEST"
  assert_contains "$(state error)" "CLAUDE_SIZE"
  [ ! -e "$BIN/claude-1.2.3" ]
  [ ! -e "$LIB/claude-1.2.3" ]
  assert_contains "$(calls notify)" "-i alert"
}

@test "outside test mode a file:// URL is not accepted" {
  CCU_TEST_MODE=0 run install 1.2.3
  [ "$status" -eq 0 ]
  assert_contains "$(state error)" "CLAUDE_URL"
}

@test "the wget fallback downloads the same way" {
  cat >"$FAKEROOT/stubs/bin/wget" <<'STUB'
#!/usr/bin/env bash
printf 'wget' >>"${FAKEROOT:?}/calls.log"
for a in "$@"; do printf ' %q' "$a" >>"$FAKEROOT/calls.log"; done
printf '
' >>"$FAKEROOT/calls.log"
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -O)
      out=$2
      shift 2
      ;;
    --)
      shift
      url=$1
      shift
      ;;
    -*) shift ;;
    *)
      url=$1
      shift
      ;;
  esac
done
cp "${url#file://}" "$out"
STUB
  chmod 0755 "$FAKEROOT/stubs/bin/wget"
  export CCU_FORCE_WGET=1
  run install 1.2.3
  [ "$status" -eq 0 ]
  [ "$(state source)" = download ]
  assert_contains "$(calls wget)" "--max-redirect=3"
  cmp -s "$LIB/claude-1.2.3" "$BUCKET/1.2.3/linux-x64/claude"
}

@test "running twice is idempotent" {
  install 1.2.3 >/dev/null
  run install 1.2.3
  [ "$status" -eq 0 ]
  [ "$(state source)" = cache ]
  [ "$(state version)" = 1.2.3 ]
  [ "$(ls "$LIB")" = "claude-1.2.3" ]
}
