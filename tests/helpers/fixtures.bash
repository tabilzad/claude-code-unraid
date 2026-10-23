#!/usr/bin/env bash
# Shared bats helpers: a fake root for the plugin scripts.
#
# Every plugin script prefixes absolute paths with "${ROOT:-}", so tests point
# ROOT at a throwaway directory that mimics the parts of an Unraid host the
# scripts touch. Stub commands (logger, notify, ...) live in $FAKEROOT/stubs/bin
# and append their arguments to $FAKEROOT/calls.log for assertions.

bats_require_minimum_version 1.5.0

PLUGIN=claude-code-unraid
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PLUGIN_SRC="$REPO_ROOT/src/usr/local/emhttp/plugins/$PLUGIN"
SCRIPTS="$PLUGIN_SRC/scripts"
BIN_SRC="$REPO_ROOT/src/usr/local/bin"
export PLUGIN REPO_ROOT PLUGIN_SRC SCRIPTS BIN_SRC

# make_fakeroot [array-state]
#   Creates $FAKEROOT with the standard layout and exports ROOT and PATH.
#   array-state is STARTED or STOPPED (default STOPPED).
make_fakeroot() {
  local state="${1:-STOPPED}"
  FAKEROOT="${BATS_TEST_TMPDIR:?}/root"
  export FAKEROOT ROOT="$FAKEROOT"
  mkdir -p \
    "$FAKEROOT/boot/config/plugins/$PLUGIN" \
    "$FAKEROOT/mnt/user/appdata" \
    "$FAKEROOT/mnt/cache/appdata" \
    "$FAKEROOT/mnt/disk1" \
    "$FAKEROOT/proc/self" \
    "$FAKEROOT/run" \
    "$FAKEROOT/tmp" \
    "$FAKEROOT/etc/claude-code/managed-settings.d" \
    "$FAKEROOT/var/local/emhttp" \
    "$FAKEROOT/var/log/plugins" \
    "$FAKEROOT/usr/local/emhttp/plugins/$PLUGIN" \
    "$FAKEROOT/usr/local/emhttp/webGui/scripts" \
    "$FAKEROOT/usr/local/lib" \
    "$FAKEROOT/usr/local/bin" \
    "$FAKEROOT/stubs/bin"

  write_var_ini "$state"
  write_disks_ini "-"
  printf 'version="7.0.0"\n' >"$FAKEROOT/etc/unraid-version"
  printf 'DOCKER_APP_CONFIG_PATH="/mnt/user/appdata/"\nDOCKER_ENABLED="yes"\n' >"$FAKEROOT/boot/config/docker.cfg"
  write_mountinfo "$state"

  : >"$FAKEROOT/calls.log"
  make_stub logger
  make_stub notify
  # Unraid's notify lives under webGui/scripts; the plugin calls it by path.
  cp "$FAKEROOT/stubs/bin/notify" "$FAKEROOT/usr/local/emhttp/webGui/scripts/notify"
  export PATH="$FAKEROOT/stubs/bin:$PATH"
}

# write_var_ini STARTED|STOPPED
write_var_ini() {
  local state="$1" fs="Stopped"
  [ "$state" = STARTED ] && fs="Started"
  cat >"$FAKEROOT/var/local/emhttp/var.ini" <<INI
version="7.0.0"
NAME="tower"
mdState="$state"
fsState="$fs"
shareDisk="no"
csrf_token="0123456789ABCDEF"
INI
}

# write_disks_ini EXPORT   (EXPORT is "-", "e" or "eh")
write_disks_ini() {
  cat >"$FAKEROOT/var/local/emhttp/disks.ini" <<INI
["flash"]
idx="31"
name="flash"
device="sda"
fsType="vfat"
export="$1"
security="public"
["cache"]
idx="30"
name="cache"
fsType="btrfs"
export="-"
INI
}

# write_mountinfo STARTED|STOPPED
#   A trimmed /proc/self/mountinfo. With the array started, /mnt/user (FUSE),
#   /mnt/cache and /mnt/disk1 are mounted; stopped, only /boot is.
write_mountinfo() {
  {
    printf '21 1 0:20 / / rw,relatime shared:1 - rootfs rootfs rw\n'
    printf '30 21 8:1 / /boot rw,noatime,nodiratime - vfat /dev/sda1 rw,fmask=0177,dmask=0077\n'
    printf '31 21 0:25 / /run rw,nosuid,nodev - tmpfs tmpfs rw\n'
    if [ "$1" = STARTED ]; then
      printf '40 21 0:40 / /mnt/disk1 rw,noatime - xfs /dev/md1p1 rw\n'
      printf '41 21 0:41 / /mnt/cache rw,noatime - btrfs /dev/nvme0n1p1 rw\n'
      printf '42 21 0:42 / /mnt/user rw,nosuid,nodev,noatime - fuse.shfs shfs rw,user_id=0,group_id=0\n'
    fi
  } >"$FAKEROOT/proc/self/mountinfo"
}

# make_stub NAME [body]
#   Creates $FAKEROOT/stubs/bin/NAME that logs "NAME <args>" to calls.log and
#   runs the optional body (a shell snippet) afterwards.
make_stub() {
  local name="$1" body="${2:-}"
  cat >"$FAKEROOT/stubs/bin/$name" <<STUB
#!/usr/bin/env bash
printf '%s' "$name" >> "$FAKEROOT/calls.log"
for a in "\$@"; do printf ' %q' "\$a" >> "$FAKEROOT/calls.log"; done
printf '\n' >> "$FAKEROOT/calls.log"
$body
STUB
  chmod 0755 "$FAKEROOT/stubs/bin/$name"
}

# calls [NAME]  -> prints logged stub calls, optionally only for NAME
calls() {
  if [ $# -eq 0 ]; then
    cat "$FAKEROOT/calls.log"
  else
    grep -E "^$1( |\$)" "$FAKEROOT/calls.log" || true
  fi
}

# assert_eq EXPECTED ACTUAL [MESSAGE]
assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'assert_eq failed%s\n  expected: %s\n  actual:   %s\n' "${3:+ ($3)}" "$1" "$2" >&2
    return 1
  fi
}

# assert_contains HAYSTACK NEEDLE
assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  printf 'assert_contains failed\n  needle: %s\n  in:     %s\n' "$2" "$1" >&2
  return 1
}

# assert_not_contains HAYSTACK NEEDLE
assert_not_contains() {
  case "$1" in
    *"$2"*)
      printf 'assert_not_contains failed\n  needle: %s\n  in:     %s\n' "$2" "$1" >&2
      return 1
      ;;
  esac
  return 0
}

# assert_file_mode PATH OCTAL
assert_file_mode() {
  local actual
  actual=$(stat -c '%a' "$1")
  assert_eq "$2" "$actual" "mode of $1"
}
