#!/usr/bin/env bats
# scripts/install-tmux against a file:// mirror holding a tiny fake package.

load '../helpers/fixtures'

SCRIPT_UNDER_TEST="$SCRIPTS/install-tmux"

setup() {
  make_fakeroot
  export CCU_TEST_MODE=1
  MIRROR="$BATS_TEST_TMPDIR/mirror"
  PKG=tmux-3.2a-x86_64-1.txz
  make_pkg "$PKG"
  CACHE="$FAKEROOT/boot/config/plugins/$PLUGIN/pkg"
  TARGET="$FAKEROOT/usr/local/lib/$PLUGIN/bin/tmux"
  STATE="$FAKEROOT/run/$PLUGIN/tmux.state"
}

# make_pkg NAME [without-binary]
make_pkg() {
  local root="$BATS_TEST_TMPDIR/pkgroot-$1"
  rm -rf "$root"
  mkdir -p "$root/usr/bin" "$root/install" "$MIRROR"
  if [ "${2:-}" != without-binary ]; then
    printf '#!/bin/bash\necho "tmux 3.2a"\n' >"$root/usr/bin/tmux"
    chmod 0755 "$root/usr/bin/tmux"
  fi
  printf 'tmux: tmux\n' >"$root/install/slack-desc"
  (cd "$root" && tar -cJf "$MIRROR/$1" usr install)
}
pkg_sha() { sha256sum "$MIRROR/$1" | cut -d' ' -f1; }

# install [PKG] [URL] [SHA]
install() {
  local pkg=${1:-$PKG} url=${2:-file://$MIRROR/${1:-$PKG}} sha=${3:-$(pkg_sha "${1:-$PKG}")}
  TMUX_PKG="$pkg" TMUX_URL="$url" TMUX_SHA256="$sha" TMUX_SIZE="$(stat -c %s "$MIRROR/$pkg" 2>/dev/null || echo 100)" "$SCRIPT_UNDER_TEST"
}
state() { sed -n "s/^$1=//p" "$STATE"; }

@test "fresh install: fetches, verifies, caches and extracts usr/bin/tmux only" {
  run install
  [ "$status" -eq 0 ]
  [ "$(state version)" = 3.2a ]
  [ "$(state source)" = download ]
  [ "$(state path)" = "$TARGET" ]
  [ -z "$(state error)" ]
  assert_file_mode "$TARGET" 755
  [ "$("$TARGET")" = "tmux 3.2a" ]
  [ -f "$CACHE/$PKG" ]
  [ -f "$CACHE/$PKG.sha256" ]
  [ ! -e "$FAKEROOT/usr/local/lib/$PLUGIN/install" ]
  [ -z "$(find "$FAKEROOT/run/$PLUGIN" -maxdepth 1 -name 'tmux.*' -type d)" ]
  [ -z "$(calls notify)" ]
}

@test "a valid cache is reused without downloading" {
  install >/dev/null
  rm -f "$TARGET"
  run install "$PKG" "file://$MIRROR/does-not-exist/$PKG"
  [ "$status" -eq 0 ]
  [ "$(state source)" = cache ]
  [ -x "$TARGET" ]
}

@test "a corrupt cache is re-downloaded" {
  install >/dev/null
  printf 'corrupt' >"$CACHE/$PKG"
  run install
  [ "$status" -eq 0 ]
  [ "$(state source)" = download ]
  cmp -s "$CACHE/$PKG" "$MIRROR/$PKG"
}

@test "download failure degrades with a warning and exits 0" {
  run install "$PKG" "file://$MIRROR/does-not-exist/$PKG"
  [ "$status" -eq 0 ]
  [ -z "$(state version)" ]
  assert_contains "$(state error)" "download failed"
  [ ! -e "$TARGET" ]
  assert_contains "$(calls notify)" "-i warning"
  assert_contains "$(calls notify)" 'tmux\ unavailable'
}

@test "a sha256 mismatch is rejected" {
  run install "$PKG" "" "0000000000000000000000000000000000000000000000000000000000000000"
  [ "$status" -eq 0 ]
  assert_contains "$(state error)" "sha256 mismatch"
  [ ! -e "$CACHE/$PKG" ]
  [ ! -e "$TARGET" ]
}

@test "a package without usr/bin/tmux is rejected after verification" {
  make_pkg tmux-3.3-x86_64-1.txz without-binary
  run install tmux-3.3-x86_64-1.txz
  [ "$status" -eq 0 ]
  assert_contains "$(state error)" "does not contain usr/bin/tmux"
  [ ! -e "$TARGET" ]
}

@test "invalid parameters are refused" {
  run env TMUX_PKG="screen-4.9-x86_64-1.txz" TMUX_URL="file://$MIRROR/$PKG" TMUX_SHA256="$(pkg_sha "$PKG")" "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  assert_contains "$(state error)" "TMUX_PKG"
  run env TMUX_PKG="$PKG" TMUX_URL="https://evil.example/$PKG" TMUX_SHA256="$(pkg_sha "$PKG")" "$SCRIPT_UNDER_TEST"
  assert_contains "$(state error)" "TMUX_URL"
  run env TMUX_PKG="$PKG" TMUX_URL="file://$MIRROR/$PKG" TMUX_SHA256="nope" "$SCRIPT_UNDER_TEST"
  assert_contains "$(state error)" "TMUX_SHA256"
  [ ! -e "$TARGET" ]
}

@test "a symlink at the tmux target is refused" {
  mkdir -p "$(dirname "$TARGET")"
  ln -s "$FAKEROOT/etc/unraid-version" "$TARGET"
  run install
  [ "$status" -eq 0 ]
  assert_contains "$(state error)" "not a regular file"
  [ -L "$TARGET" ]
}

@test "older cached tmux packages are pruned to current plus one" {
  mkdir -p "$CACHE"
  for p in tmux-3.0-x86_64-1.txz tmux-3.1-x86_64-1.txz; do
    printf 'old' >"$CACHE/$p"
  done
  touch -d '2026-01-01' "$CACHE/tmux-3.0-x86_64-1.txz"
  touch -d '2026-01-02' "$CACHE/tmux-3.1-x86_64-1.txz"
  install >/dev/null
  run ls "$CACHE"
  assert_contains "$output" "tmux-3.1-x86_64-1.txz"
  assert_not_contains "$output" "tmux-3.0-x86_64-1.txz"
  assert_contains "$output" "$PKG"
}
