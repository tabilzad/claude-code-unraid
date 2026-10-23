#!/usr/bin/env bash
# Emulated Unraid host: the whole plugin life cycle through Lime's real plugin
# manager and the real pkgtools, inside the dev container as root.
#
#   DEV_ENV_DOCKER_ARGS=--privileged ./scripts/dev-env --root make e2e
#
# What is emulated: a flash drive (tmpfs on /boot when privileged), the array
# (tmpfs on /mnt/user and /mnt/cache), emhttpd's var.ini and disks.ini, the
# notify script, a release bucket served over file:// (test mode) holding a
# stub Claude binary and a fake tmux package, and the event scripts called the
# way emhttpd calls them. The Debian-based dev image stands in for Slackware:
# the Slackware image has no PHP (which the plugin manager and the hooks need),
# while the dev image carries Slackware 15.0 pkgtools, so package handling is
# identical.
#
# --privileged is needed for the mount namespace the launcher uses (unshare)
# and for the tmpfs mounts. Without it the mount-related checks are skipped
# and reported as such.
#
# Scenarios:
#   1 fresh install, array stopped       fallback mode, binary and tmux fetched
#   2 disks_mounted                      pool mode, data directories created
#   3 supervised session start           stub claude runs in the fake tmux
#   4 stopping                           session stopped and flagged, fallback
#   5 reboot                             RAM wiped, reinstall from flash cache only
#   6 disks_mounted again                restore brings the session back (--resume)
#   7 plugin update                      new binary, previous kept, cache pruned
#   8 corrupt cache + network down       previous version used, plg not disabled
#   9 remove                             RAM side gone, cfg and data kept
set -uo pipefail

PLUGIN=claude-code-unraid
REPO=${REPO_ROOT:-/work}
E2E=/tmp/e2e
PDIR="/usr/local/emhttp/plugins/$PLUGIN"
FLASH="/boot/config/plugins/$PLUGIN"
LIB="/usr/local/lib/$PLUGIN"
RUN="/run/$PLUGIN"
DATA="/mnt/user/appdata/$PLUGIN"
pass_n=0
skip_n=0

fail() {
  printf 'e2e: FAIL: %s\n' "$*" >&2
  printf -- '--- install log ---\n' >&2
  tail -n 40 "/var/log/$PLUGIN/install.log" 2>/dev/null >&2
  local f
  for f in "$E2E"/install*.log "$E2E"/plugin-manager.log; do
    [ -f "$f" ] || continue
    printf -- '--- %s ---
' "$f" >&2
    tail -n 60 "$f" >&2
  done
  exit 1
}
step() { printf '\n==> %s\n' "$*"; }
ok() {
  printf '  ok   %s\n' "$*"
  pass_n=$((pass_n + 1))
}
skip() {
  printf '  skip %s\n' "$*"
  skip_n=$((skip_n + 1))
}
assert() {
  local msg=$1
  shift
  if "$@"; then ok "$msg"; else fail "$msg"; fi
}
assert_not() {
  local msg=$1
  shift
  if "$@"; then fail "$msg"; else ok "$msg"; fi
}
state() { sed -n "s/^$2=//p" "$RUN/$1.state"; }
count_files() { # GLOB...: how many of the given paths exist
  local n=0 f
  for f in "$@"; do [ -e "$f" ] && n=$((n + 1)); done
  echo "$n"
}
count_cached_binaries() { # cached Claude binaries on flash, sidecars excluded
  local n=0 f
  for f in "$FLASH"/bin/claude-*; do
    case "$f" in *.sha256) continue ;; esac
    [ -e "$f" ] && n=$((n + 1))
  done
  echo "$n"
}
plugin() { php /usr/local/sbin/plugin "$@"; }
event() { "$PDIR/event/$1"; }

[ "${IN_DEV_ENV:-}" = 1 ] || fail "run inside the dev container: DEV_ENV_DOCKER_ARGS=--privileged ./scripts/dev-env --root make e2e"
[ "$(id -u)" = 0 ] || fail "must run as root inside the container"

# ---------------------------------------------------------------------------
step "host emulation"
rm -rf "$E2E" /var/log/plugins /tmp/plugins "$PDIR" "$LIB" "$RUN" /etc/claude-code /var/lib/pkgtools "/var/log/$PLUGIN"
umount /boot /mnt/user /mnt/cache 2>/dev/null || true
mkdir -p "$E2E/bin" "$E2E/bucket" /boot /mnt/user /mnt/cache /var/log/plugins /tmp/plugins /var/local/emhttp \
  /usr/local/emhttp/webGui/include /usr/local/emhttp/webGui/scripts /usr/local/sbin
PRIV=0
if mount -t tmpfs -o size=64m tmpfs /boot 2>/dev/null && mount -t tmpfs -o size=64m tmpfs /mnt/user 2>/dev/null && mount -t tmpfs -o size=64m tmpfs /mnt/cache 2>/dev/null; then
  PRIV=1
  ok "privileged: tmpfs mounted on /boot, /mnt/user and /mnt/cache"
else
  skip "not privileged: /boot and /mnt are plain directories; mount checks are skipped"
fi
rm -rf /boot/config
mkdir -p /boot/config/plugins /mnt/user/appdata /mnt/cache/appdata
printf 'version="7.0.0"\n' >/etc/unraid-version
printf 'DOCKER_APP_CONFIG_PATH="/mnt/user/appdata/"\n' >/boot/config/docker.cfg
set_array() { # STARTED|STOPPED
  local fs=Stopped
  [ "$1" = STARTED ] && fs=Started
  printf 'version="7.0.0"\nNAME="tower"\nmdState="%s"\nfsState="%s"\ncsrf_token="E2E"\n' "$1" "$fs" >/var/local/emhttp/var.ini
}
set_array STOPPED
printf '["flash"]\nname="flash"\nexport="-"\nsecurity="public"\n' >/var/local/emhttp/disks.ini
cat >/usr/local/emhttp/webGui/include/Wrappers.php <<'PHP'
<?php
function my_logger($message, $logger = 'plugin') {
  file_put_contents('/tmp/e2e/plugin-manager.log', "[$logger] $message\n", FILE_APPEND);
}
PHP
printf '<?php\nfunction publish() {}\n' >/usr/local/emhttp/webGui/include/publish.php
printf '#!/bin/bash\nprintf "notify %%s\\n" "$*" >> /tmp/e2e/notify.log\n' >/usr/local/emhttp/webGui/scripts/notify
chmod 0755 /usr/local/emhttp/webGui/scripts/notify
install -m 0755 "$REPO/tests/vendor/unraid/plugin" /usr/local/sbin/plugin
printf '#!/bin/bash\nprintf "logger %%s\\n" "$*" >> /tmp/e2e/syslog\n' >"$E2E/bin/logger"
printf '#!/bin/bash\necho "wget called: $*" >> /tmp/e2e/wget.log\nexit 4\n' >"$E2E/bin/wget"
chmod 0755 "$E2E/bin/logger" "$E2E/bin/wget"
export PATH="$E2E/bin:$PATH"
export CCU_TEST_MODE=1

# Release bucket: two stub Claude "releases" and a fake tmux package.
make_release() { # VER
  mkdir -p "$E2E/bucket/$1/linux-x64"
  sed "s/@VER@/$1/" "$REPO/tests/e2e/stub-claude.bash" >"$E2E/bucket/$1/linux-x64/claude"
  chmod 0755 "$E2E/bucket/$1/linux-x64/claude"
}
make_release 9.0.1
make_release 9.0.2
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
size_of() { stat -c %s "$1"; }
mkdir -p "$E2E/tmuxpkg/usr/bin" "$E2E/tmuxpkg/install"
{
  cat <<'EOF'
#!/usr/bin/env bash
# fake tmux for the emulated host: the state dir has a default here
export FAKE_TMUX_STATE="${FAKE_TMUX_STATE:-/run/claude-code-unraid/fake-tmux}"
EOF
  tail -n +2 "$REPO/tests/helpers/fake-tmux.bash"
} >"$E2E/tmuxpkg/usr/bin/tmux"
chmod 0755 "$E2E/tmuxpkg/usr/bin/tmux"
printf 'tmux: fake\n' >"$E2E/tmuxpkg/install/slack-desc"
(cd "$E2E/tmuxpkg" && tar -cJf "$E2E/bucket/tmux-3.2a-x86_64-1.txz" usr install)

# Packages and plgs for two plugin versions, pointed at the bucket.
build_plg() { # PLUGIN_VERSION CLAUDE_VER OUT
  local pver=$1 cver=$2 out=$3 txz plg
  txz=$("$REPO/scripts/build-txz" --version "$pver" --out-dir "$E2E/dist")
  plg="$E2E/$out"
  mkdir -p -- "$(dirname -- "$plg")"
  "$REPO/scripts/render-plg" --version "$pver" --plugin-version 0.0.0-dev --txz "$txz" \
    --txz-url "https://127.0.0.1:1/never/$(basename "$txz")" --out "$plg" >/dev/null
  # test variant: Claude and tmux come from the local bucket (CCU_TEST_MODE honours file://)
  sed -i \
    -e "s|^<!ENTITY claudeVersion \"[^\"]*\">|<!ENTITY claudeVersion \"$cver\">|" \
    -e "s|^<!ENTITY claudeSHA256  \"[^\"]*\">|<!ENTITY claudeSHA256  \"$(sha_of "$E2E/bucket/$cver/linux-x64/claude")\">|" \
    -e "s|^<!ENTITY claudeURL     \"[^\"]*\">|<!ENTITY claudeURL     \"file://$E2E/bucket/$cver/linux-x64/claude\">|" \
    -e "s|^<!ENTITY claudeSize    \"[^\"]*\">|<!ENTITY claudeSize    \"$(size_of "$E2E/bucket/$cver/linux-x64/claude")\">|" \
    -e "s|^<!ENTITY tmuxURL       \"[^\"]*\">|<!ENTITY tmuxURL       \"file://$E2E/bucket/tmux-3.2a-x86_64-1.txz\">|" \
    -e "s|^<!ENTITY tmuxSHA256    \"[^\"]*\">|<!ENTITY tmuxSHA256    \"$(sha_of "$E2E/bucket/tmux-3.2a-x86_64-1.txz")\">|" \
    -e "s|^<!ENTITY tmuxSize      \"[^\"]*\">|<!ENTITY tmuxSize      \"$(size_of "$E2E/bucket/tmux-3.2a-x86_64-1.txz")\">|" \
    "$plg"
  mkdir -p "$FLASH/pkg"
  cp "$txz" "$FLASH/pkg/" # the package is "cached" (its URL never resolves here)
  printf '%s' "$plg"
}
PLG1=$(build_plg 2026.01.01.1 9.0.1 v1/claude-code-unraid.plg)
ok "built plugin 2026.01.01.1 (Claude 9.0.1) and the fake release bucket"

# ---------------------------------------------------------------------------
step "1. fresh install with the array stopped"
plugin install "$PLG1" >"$E2E/install1.log" 2>&1 || {
  cat "$E2E/install1.log"
  fail "plugin install"
}
assert "plg registered" test -L "/var/log/plugins/$PLUGIN.plg"
assert "package installed" test -x "$PDIR/scripts/install-binary"
assert "binary downloaded from the bucket" test "$(state binary source)" = download
assert "binary 9.0.1 in RAM" test -x "$LIB/claude-9.0.1"
assert "binary cached on flash with sidecar" test -f "$FLASH/bin/claude-9.0.1.sha256"
assert "tmux extracted" test -x "$LIB/bin/tmux"
assert "policy baseline written" test -f "/etc/claude-code/managed-settings.d/99-$PLUGIN-baseline.json"
assert "fallback mode" test "$(cat "$RUN/mode")" = fallback
assert "launcher and helper installed" test -x /usr/local/bin/claude -a -x /usr/local/bin/claude-unraid
assert_not "nothing hit the network" test -e "$E2E/wget.log"
if [ "$PRIV" = 1 ]; then
  out=$(cd /tmp && claude --version 2>&1) || fail "claude --version through the launcher: $out"
  assert "claude --version runs through the read-only wrapper" grep -q 'stub claude 9.0.1' <<<"$out"
  if STUB_EXEC='touch /boot/probe' claude >/dev/null 2>&1; then fail "a session could write to /boot"; fi
  assert_not "/boot is read-only inside a session" test -e /boot/probe
  touch /boot/probe-outside && ok "/boot stays writable outside the session" && rm -f /boot/probe-outside
  rc=0
  claude --boot-rw >/dev/null 2>&1 || rc=$?
  assert "--boot-rw refused by default (exit $rc)" test "$rc" = 80
else
  skip "launcher mount namespace (needs --privileged)"
fi
assert "status --json works" claude-unraid status --json
assert "doctor reports the fallback data directory as a warning" bash -c 'claude-unraid doctor | grep -q "WARN  data directory"'

# ---------------------------------------------------------------------------
step "2. disks_mounted"
set_array STARTED
event disks_mounted
assert "pool mode" test "$(cat "$RUN/mode")" = pool
assert "data directories created" test -d "$DATA/config" -a -d "$DATA/work/server"
assert "config dir mode 0700" test "$(stat -c %a "$DATA/config")" = 700
assert "no share was created" test ! -e /mnt/user/claude -a ! -e "/mnt/cache/$PLUGIN"
event started
assert "started summary logged" grep -q 'array started: mode pool' "$E2E/syslog"

# ---------------------------------------------------------------------------
step "3. supervised session"
claude-unraid start server >"$E2E/start.log" 2>&1 || {
  cat "$E2E/start.log"
  fail "start server"
}
sleep 1
assert "session listed as running" bash -c 'claude-unraid list | grep -q "server.*running"'
assert "registry has a live supervised entry" test -n "$("$PDIR/scripts/registry" live "$DATA/sessions.json" server)"
SID=$("$PDIR/scripts/registry" live "$DATA/sessions.json" server)
assert "session pid recorded and alive" kill -0 "$(cat "$RUN/sessions/server.pid")"
assert_not "mode switch refused under a live session" "$PDIR/scripts/mode" set fallback

# ---------------------------------------------------------------------------
step "4. stopping"
SECONDS=0
event stopping
assert "stopping finished within 15s" test "$SECONDS" -lt 15
assert "fallback mode" test "$(cat "$RUN/mode")" = fallback
sleep 0.5
assert "session gone" bash -c '! claude-unraid list | grep -q running'
assert "entry flagged for restore" bash -c "'$PDIR/scripts/registry' list '$DATA/sessions.json' | grep -q \"$SID.*yes\$\""
event unmounting_disks
event stopping_array 2>/dev/null || true
ok "stopping_array has no handler (disks already unmounted there)"

# ---------------------------------------------------------------------------
step "5. reboot: RAM wiped, reinstall from the flash cache, bucket unreachable"
rm -rf "$PDIR" "$LIB" "$RUN" /etc/claude-code /var/lib/pkgtools /var/log/plugins/* /tmp/plugins/* "/var/log/$PLUGIN"
mv "$E2E/bucket" "$E2E/bucket.away"
set_array STOPPED
plugin install "/boot/config/plugins/$PLUGIN.plg" >"$E2E/install2.log" 2>&1 || {
  cat "$E2E/install2.log"
  fail "reboot install"
}
assert "plg registered again" test -L "/var/log/plugins/$PLUGIN.plg"
assert "binary came from the flash cache" test "$(state binary source)" = cache
assert "tmux came from the flash cache" test "$(state tmux source)" = cache
assert_not "plg not in plugins-error" test -e "/boot/config/plugins-error/$PLUGIN.plg"
assert "fallback mode after boot" test "$(cat "$RUN/mode")" = fallback
mv "$E2E/bucket.away" "$E2E/bucket"

# ---------------------------------------------------------------------------
step "6. disks_mounted again: the session comes back"
set_array STARTED
event disks_mounted
for _ in $(seq 1 60); do
  grep -q 'restore: [0-9]* resumed' "/var/log/$PLUGIN/install.log" 2>/dev/null && break
  sleep 0.5
done
assert "restore finished and logged" grep -q 'restore: 1 resumed, 0 started fresh, 0 failed' "/var/log/$PLUGIN/install.log"
assert "restored session running" bash -c 'claude-unraid list | grep -q "server.*running"'
assert "restore resumed the recorded session id" grep -q "args:--resume $SID" "$RUN/fake-tmux/$PLUGIN-server/out"
assert "restore flag cleared" bash -c "! '$PDIR/scripts/registry' list '$DATA/sessions.json' | grep -q \"$SID.*yes\$\""
assert "restore notification raised" grep -q 'Claude Code sessions restored' "$E2E/notify.log"

# ---------------------------------------------------------------------------
step "7. plugin update to 2026.01.01.2 with Claude 9.0.2"
PLG2=$(build_plg 2026.01.01.2 9.0.2 v2/claude-code-unraid.plg)
plugin install "$PLG2" >"$E2E/install3.log" 2>&1 || {
  cat "$E2E/install3.log"
  fail "update install"
}
assert "new binary active" test "$(state binary version)" = 9.0.2
assert "downloaded" test "$(state binary source)" = download
assert "previous version kept on flash" test -f "$FLASH/bin/claude-9.0.1"
assert "only two versions cached" test "$(count_cached_binaries)" = 2
assert "old RAM copy pruned" test ! -e "$LIB/claude-9.0.1"
assert "old package pruned from flash" test "$(count_files "$FLASH"/pkg/"$PLUGIN"-*.txz)" = 1
assert "package db shows the new version" test "$(count_files /var/lib/pkgtools/packages/"$PLUGIN"-2026.01.01.2-*)" = 1
assert "mode kept during the update" test "$(cat "$RUN/mode")" = pool
claude-unraid stop --all --timeout 5 >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
step "8. corrupt cache and no network: previous version used, plg stays installed"
rm -rf "$PDIR" "$LIB" "$RUN" /etc/claude-code /var/lib/pkgtools /var/log/plugins/* /tmp/plugins/* "/var/log/$PLUGIN"
printf 'corrupt' >"$FLASH/bin/claude-9.0.2"
mv "$E2E/bucket" "$E2E/bucket.away"
: >"$E2E/notify.log"
set_array STOPPED
plugin install "/boot/config/plugins/$PLUGIN.plg" >"$E2E/install4.log" 2>&1 || {
  cat "$E2E/install4.log"
  fail "degraded install"
}
assert "plg still registered" test -L "/var/log/plugins/$PLUGIN.plg"
assert_not "plg not in plugins-error" test -e "/boot/config/plugins-error/$PLUGIN.plg"
assert "previous version 9.0.1 active" test "$(state binary version)" = 9.0.1
assert "source=previous" test "$(state binary source)" = previous
assert "error recorded" test -n "$(state binary error)"
assert "warning notification raised" grep -q 'warning' "$E2E/notify.log"
assert "launcher runs the previous version" bash -c 'cd /tmp && claude --version 2>/dev/null | grep -q "stub claude 9.0.1"' || true
mv "$E2E/bucket.away" "$E2E/bucket"

# ---------------------------------------------------------------------------
step "9. remove"
printf 'DATA_DIR=""\nRESTORE_SESSIONS="yes"\n' >"$FLASH/$PLUGIN.cfg"
mkdir -p "$FLASH/policy.d"
printf '{"permissions":{"allow":["Bash(ls *)"]}}\n' >"$FLASH/policy.d/mine.json"
plugin remove "$PLUGIN.plg" >"$E2E/remove.log" 2>&1 || {
  cat "$E2E/remove.log"
  fail "remove"
}
assert "RAM side gone" test ! -e "$PDIR" -a ! -e "$LIB" -a ! -e "$RUN" -a ! -e /usr/local/bin/claude -a ! -e /usr/local/bin/claude-unraid
assert "policy baseline gone" test ! -e "/etc/claude-code/managed-settings.d/99-$PLUGIN-baseline.json"
assert "flash caches gone" test ! -e "$FLASH/bin" -a ! -e "$FLASH/pkg"
assert "cfg and policy.d kept" test -f "$FLASH/$PLUGIN.cfg" -a -f "$FLASH/policy.d/mine.json"
assert "data directory kept" test -d "$DATA/config"
assert "plg moved to plugins-removed" test -f "/boot/config/plugins-removed/$PLUGIN.plg"
assert "remove told the user what was kept" grep -q 'Kept, because they are yours' "$E2E/remove.log"

printf '\ne2e: all scenarios passed (%s checks, %s skipped)\n' "$pass_n" "$skip_n"
