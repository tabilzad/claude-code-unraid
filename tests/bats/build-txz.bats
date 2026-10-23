#!/usr/bin/env bats
# scripts/build-txz: package layout, modes, CRLF stripping, reproducibility, and
# a real installpkg/removepkg round trip into a fake root.

load '../helpers/fixtures'

SCRIPT="$REPO_ROOT/scripts/build-txz"

setup() {
  make_fakeroot
  SRC="$BATS_TEST_TMPDIR/src"
  DIST="$BATS_TEST_TMPDIR/dist"
  cp -R "$REPO_ROOT/src" "$SRC"
  local pdir="$SRC/usr/local/emhttp/plugins/$PLUGIN"
  mkdir -p "$pdir/scripts" "$pdir/event" "$SRC/usr/local/bin"
  printf '#!/bin/bash\r\necho crlf\r\n' >"$pdir/scripts/crlf-script"
  printf '#!/bin/bash\necho handler\n' >"$pdir/event/disks_mounted"
  printf '#!/bin/bash\necho tool\n' >"$SRC/usr/local/bin/tool"
  printf '# readme\r\n' >"$pdir/README.md"
  chmod 0600 "$pdir/scripts/crlf-script" "$pdir/README.md" # modes must come from the build, not the tree
}

build() {
  "$SCRIPT" --src "$SRC" --out-dir "$DIST" "$@"
}

@test "builds NAME-VERSION-noarch-1.txz with makepkg layout and modes" {
  run build --version 2026.01.02.3
  [ "$status" -eq 0 ]
  [ "$output" = "$DIST/$PLUGIN-2026.01.02.3-noarch-1.txz" ]
  [ -f "$DIST/$PLUGIN-2026.01.02.3-noarch-1.txz.sha256" ]
  run tar -tvJf "$DIST/$PLUGIN-2026.01.02.3-noarch-1.txz"
  [ "$status" -eq 0 ]
  [ "${lines[0]##* }" = "./" ]
  assert_contains "$output" "-rwxr-xr-x 0/0"
  grep -qE "^-rwxr-xr-x 0/0 .* usr/local/emhttp/plugins/$PLUGIN/scripts/crlf-script$" <<<"$output"
  grep -qE "^-rwxr-xr-x 0/0 .* usr/local/emhttp/plugins/$PLUGIN/event/disks_mounted$" <<<"$output"
  grep -qE "^-rwxr-xr-x 0/0 .* usr/local/bin/tool$" <<<"$output"
  grep -qE "^-rw-r--r-- 0/0 .* usr/local/emhttp/plugins/$PLUGIN/README.md$" <<<"$output"
  grep -qE "^-rw-r--r-- 0/0 .* install/slack-desc$" <<<"$output"
  grep -qE "^drwxr-xr-x 0/0 .* usr/local/emhttp/plugins/$PLUGIN/$" <<<"$output"
  run ! grep -qE ' \./usr' <<<"$output"
  run ! grep -q '\.gitkeep' <<<"$output"
}

@test "strips CR from text files" {
  build --version 2026.01.02.3 >/dev/null
  run bash -c "tar -xJOf '$DIST/$PLUGIN-2026.01.02.3-noarch-1.txz' usr/local/emhttp/plugins/$PLUGIN/scripts/crlf-script usr/local/emhttp/plugins/$PLUGIN/README.md | od -c | grep -c '\\\\r'"
  [ "$output" = "0" ]
}

@test "refuses a script without a shebang" {
  printf 'echo no shebang\n' >"$SRC/usr/local/emhttp/plugins/$PLUGIN/scripts/broken"
  run build --version 2026.01.02.3
  [ "$status" -ne 0 ]
  assert_contains "$output" "not executable (missing #! line): /usr/local/emhttp/plugins/$PLUGIN/scripts/broken"
  [ ! -e "$DIST/$PLUGIN-2026.01.02.3-noarch-1.txz" ]
}

@test "dev version becomes an underscore in the package name" {
  run build
  [ "$status" -eq 0 ]
  [ "$output" = "$DIST/$PLUGIN-0000.00.00.0_dev-noarch-1.txz" ]
}

@test "rejects malformed versions" {
  for v in 2026.1.2.3 2026.01.02 2026.01.02.10 v1 '2026.01.02.3;x'; do
    run build --version "$v"
    [ "$status" -ne 0 ]
  done
}

@test "two builds of the same tree are byte-identical" {
  SOURCE_DATE_EPOCH=1700000000 build --version 2026.01.02.3 >/dev/null
  local first
  first=$(sha256sum "$DIST/$PLUGIN-2026.01.02.3-noarch-1.txz" | cut -d' ' -f1)
  rm -rf "$DIST"
  touch "$SRC/usr/local/bin/tool" # mtimes in the tree must not matter
  SOURCE_DATE_EPOCH=1700000000 build --version 2026.01.02.3 >/dev/null
  [ "$(sha256sum "$DIST/$PLUGIN-2026.01.02.3-noarch-1.txz" | cut -d' ' -f1)" = "$first" ]
}

@test "the real src tree builds" {
  run "$SCRIPT" --out-dir "$DIST"
  [ "$status" -eq 0 ]
  run tar -tJf "$DIST/$PLUGIN-0000.00.00.0_dev-noarch-1.txz"
  assert_contains "$output" "usr/local/emhttp/plugins/$PLUGIN/scripts/install-binary"
  assert_contains "$output" "install/slack-desc"
}

@test "installpkg installs it into a fake root and removepkg removes it" {
  command -v installpkg >/dev/null || skip "pkgtools not installed"
  build --version 2026.01.02.3 >/dev/null
  run env ROOT="$FAKEROOT" installpkg --terse "$DIST/$PLUGIN-2026.01.02.3-noarch-1.txz"
  [ "$status" -eq 0 ]
  [ -x "$FAKEROOT/usr/local/emhttp/plugins/$PLUGIN/scripts/crlf-script" ]
  [ -x "$FAKEROOT/usr/local/bin/tool" ]
  [ -f "$FAKEROOT/var/lib/pkgtools/packages/$PLUGIN-2026.01.02.3-noarch-1" ]
  assert_file_mode "$FAKEROOT/usr/local/emhttp/plugins/$PLUGIN/README.md" 644
  run env ROOT="$FAKEROOT" removepkg "$PLUGIN"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKEROOT/usr/local/bin/tool" ]
  [ ! -e "$FAKEROOT/var/lib/pkgtools/packages/$PLUGIN-2026.01.02.3-noarch-1" ]
}

@test "upgradepkg --install-new --reinstall replaces an older version" {
  command -v upgradepkg >/dev/null || skip "pkgtools not installed"
  build --version 2026.01.02.3 >/dev/null
  build --version 2026.01.03.1 >/dev/null
  ROOT="$FAKEROOT" installpkg --terse "$DIST/$PLUGIN-2026.01.02.3-noarch-1.txz"
  run env ROOT="$FAKEROOT" upgradepkg --install-new --reinstall "$DIST/$PLUGIN-2026.01.03.1-noarch-1.txz"
  [ "$status" -eq 0 ]
  [ -f "$FAKEROOT/var/lib/pkgtools/packages/$PLUGIN-2026.01.03.1-noarch-1" ]
  [ ! -e "$FAKEROOT/var/lib/pkgtools/packages/$PLUGIN-2026.01.02.3-noarch-1" ]
  # idempotent: the same package again
  run env ROOT="$FAKEROOT" upgradepkg --install-new --reinstall "$DIST/$PLUGIN-2026.01.03.1-noarch-1.txz"
  [ "$status" -eq 0 ]
  [ -x "$FAKEROOT/usr/local/bin/tool" ]
}
