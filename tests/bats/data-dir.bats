#!/usr/bin/env bats
# scripts/data-dir: resolution matrix and the never-create-a-share rule.

load '../helpers/fixtures'

setup() {
  make_fakeroot STARTED
  export CCU_TEST_MODE=1
  DD="$SCRIPTS/data-dir"
  CFG="$FAKEROOT/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
}

check() { "$DD" --check "$@"; }
field() { sed -n "s/^$1=//p" <<<"$output"; }

@test "auto: <appdata>/<plugin> on /mnt/user when docker.cfg points there" {
  run check
  [ "$status" -eq 0 ]
  [ "$(field DATA_DIR)" = "/mnt/user/appdata/$PLUGIN" ]
  [ "$(field SOURCE)" = auto ]
  [ "$(field VALID)" = yes ]
  [ "$(field FUSE)" = yes ]
  [ "$(field EXISTS)" = no ]
  run "$DD"
  [ "$status" -eq 0 ]
  [ "$output" = "/mnt/user/appdata/$PLUGIN" ]
}

@test "auto: prefers the pool path when the appdata share lives on one pool" {
  mkdir -p "$FAKEROOT/boot/config/shares"
  printf 'shareUseCache="only"\nshareCachePool="cache"\n' >"$FAKEROOT/boot/config/shares/appdata.cfg"
  run check
  [ "$status" -eq 0 ]
  [ "$(field DATA_DIR)" = "/mnt/cache/appdata/$PLUGIN" ]
  [ "$(field SOURCE)" = pool ]
  [ "$(field FUSE)" = no ]
  printf 'shareUseCache="prefer"\nshareCachePool="cache"\n' >"$FAKEROOT/boot/config/shares/appdata.cfg"
  run check
  [ "$(field DATA_DIR)" = "/mnt/cache/appdata/$PLUGIN" ]
}

@test "auto: keeps /mnt/user when the pool copy is not there or the share is not pool-only" {
  mkdir -p "$FAKEROOT/boot/config/shares"
  printf 'shareUseCache="only"\nshareCachePool="nvme"\n' >"$FAKEROOT/boot/config/shares/appdata.cfg"
  run check
  [ "$(field DATA_DIR)" = "/mnt/user/appdata/$PLUGIN" ]
  printf 'shareUseCache="yes"\nshareCachePool="cache"\n' >"$FAKEROOT/boot/config/shares/appdata.cfg"
  run check
  [ "$(field DATA_DIR)" = "/mnt/user/appdata/$PLUGIN" ]
}

@test "auto: docker.cfg absent or pointing elsewhere" {
  rm "$FAKEROOT/boot/config/docker.cfg"
  run check
  [ "$(field DATA_DIR)" = "/mnt/user/appdata/$PLUGIN" ]
  mkdir -p "$FAKEROOT/mnt/user/apps"
  printf 'DOCKER_APP_CONFIG_PATH="/mnt/user/apps/"\n' >"$FAKEROOT/boot/config/docker.cfg"
  run check
  [ "$(field DATA_DIR)" = "/mnt/user/apps/$PLUGIN" ]
  [ "$(field VALID)" = yes ]
}

@test "a configured DATA_DIR wins and loses its trailing slash" {
  mkdir -p "$FAKEROOT/mnt/cache/appdata"
  printf 'DATA_DIR="/mnt/cache/appdata/claude/"\n' >"$CFG"
  run check
  [ "$status" -eq 0 ]
  [ "$(field DATA_DIR)" = "/mnt/cache/appdata/claude" ]
  [ "$(field SOURCE)" = cfg ]
  [ "$(field FUSE)" = no ]
}

@test "not usable while the array is stopped" {
  write_var_ini STOPPED
  write_mountinfo STOPPED
  run check
  [ "$status" -eq 1 ]
  [ "$(field VALID)" = no ]
  assert_contains "$(field REASON)" "not mounted"
  run "$DD"
  [ "$status" -eq 1 ]
  assert_contains "$output" "not mounted"
}

@test "never creates a share: a missing top-level directory is refused, an existing one is fine" {
  run check /mnt/user/newshare
  [ "$status" -eq 1 ]
  assert_contains "$(field REASON)" "would create a new share"
  run check /mnt/cache/newtop
  [ "$status" -eq 1 ]
  assert_contains "$(field REASON)" "would create a new share"
  mkdir -p "$FAKEROOT/mnt/cache/existing"
  run check /mnt/cache/existing
  [ "$status" -eq 0 ]
  [ "$(field EXISTS)" = yes ]
  run check "/mnt/cache/appdata/$PLUGIN"
  [ "$status" -eq 0 ]
  [ "$(field EXISTS)" = no ]
}

@test "a missing parent is refused" {
  run check /mnt/user/appdata/nope/deeper
  [ "$status" -eq 1 ]
  assert_contains "$(field REASON)" "parent directory /mnt/user/appdata/nope does not exist"
}

@test "odd paths are refused" {
  run check '/mnt/user/appdata/a b'
  [ "$status" -eq 1 ]
  assert_contains "$(field REASON)" "whitespace"
  run check '/mnt/user/appdata/../etc'
  [ "$status" -eq 1 ]
  assert_contains "$(field REASON)" "'..'"
  run check /tmp/claude
  [ "$status" -eq 1 ]
  assert_contains "$(field REASON)" "must be inside a share or pool"
  run check /mnt/user
  [ "$status" -eq 1 ]
  run check /mnt
  [ "$status" -eq 1 ]
  mkdir -p "$FAKEROOT/mnt/cache/appdata/real"
  ln -s "$FAKEROOT/mnt/cache/appdata/real" "$FAKEROOT/mnt/cache/appdata/link"
  run check /mnt/cache/appdata/link
  [ "$status" -eq 1 ]
  assert_contains "$(field REASON)" "symlink"
  printf 'file' >"$FAKEROOT/mnt/cache/appdata/afile"
  run check /mnt/cache/appdata/afile
  [ "$status" -eq 1 ]
  assert_contains "$(field REASON)" "not a directory"
}

@test "--ensure creates only the leaf, mode 0700, and is idempotent" {
  run "$DD" --ensure
  [ "$status" -eq 0 ]
  [ "$(field EXISTS)" = yes ]
  assert_file_mode "$FAKEROOT/mnt/user/appdata/$PLUGIN" 700
  run "$DD" --ensure
  [ "$status" -eq 0 ]
  [ "$(field EXISTS)" = yes ]
  run "$DD" --ensure /mnt/user/newshare
  [ "$status" -eq 1 ]
  [ ! -e "$FAKEROOT/mnt/user/newshare" ]
  write_mountinfo STOPPED
  rm -rf "$FAKEROOT/mnt/user/appdata/$PLUGIN"
  run "$DD" --ensure
  [ "$status" -eq 1 ]
  [ ! -e "$FAKEROOT/mnt/user/appdata/$PLUGIN" ]
}

@test "unknown options are rejected" {
  run "$DD" --bogus
  [ "$status" -eq 64 ]
}
