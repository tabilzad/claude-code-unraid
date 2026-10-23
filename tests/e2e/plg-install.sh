#!/usr/bin/env bash
# End-to-end: run Lime Technology's real plugin manager (tests/vendor/unraid/plugin)
# against the rendered .plg inside the dev container, with a fake /boot and no
# network. Needs root inside the container because the plugin manager and
# pkgtools write to /boot, /var/log/plugins, /usr/local and /var/lib/pkgtools:
#
#   ./scripts/dev-env --root make e2e-install
#
# Scenarios:
#   A  fresh install with the package already cached on "flash" (the boot case):
#      no download, package installed, plg registered
#   B  "reboot": RAM side wiped, plg re-run from /boot/config/plugins; the cache
#      is reused and nothing is downloaded
#   C  corrupt cache and no network: the plugin manager fails the install and
#      moves the plg to plugins-error (documents the behaviour invariant 3 is
#      built around; our own package is the only element that can do this)
#   D  remove: RAM side gone, cfg kept, plg moved to plugins-removed
#   E  fresh install from a <LOCAL> package (no cache, no network)
set -euo pipefail

PLUGIN=claude-code-unraid
REPO=${REPO_ROOT:-/work}
E2E=/tmp/e2e
fail() {
  printf 'e2e-install: FAIL: %s\n' "$*" >&2
  exit 1
}
step() { printf '\n==> %s\n' "$*"; }
assert() {
  local msg=$1
  shift
  if "$@"; then printf '  ok   %s\n' "$msg"; else fail "$msg"; fi
}
assert_not() {
  local msg=$1
  shift
  if "$@"; then fail "$msg"; else printf '  ok   %s\n' "$msg"; fi
}

[ "${IN_DEV_ENV:-}" = 1 ] || fail "refusing to run outside the dev container (it writes to /boot and /usr/local)"
[ "$(id -u)" = 0 ] || fail "must run as root inside the container: ./scripts/dev-env --root make e2e-install"
command -v upgradepkg >/dev/null || fail "pkgtools missing from the image"

rm -rf "$E2E" /boot/config /var/log/plugins /tmp/plugins "/usr/local/emhttp/plugins/$PLUGIN" /var/lib/pkgtools /var/log/packages
mkdir -p "$E2E/dist" "$E2E/bin" /boot/config/plugins /var/log/plugins /tmp/plugins \
  /usr/local/emhttp/webGui/include /usr/local/emhttp/webGui/scripts /usr/local/sbin

step "build and render"
version=0000.00.00.0-dev
txz=$("$REPO/scripts/build-txz" --version "$version" --out-dir "$E2E/dist")
txz_name=$(basename "$txz")
plg="$E2E/$PLUGIN.plg"
"$REPO/scripts/render-plg" --version "$version" --plugin-version 0.0.0-dev --txz "$txz" \
  --txz-url "https://127.0.0.1:1/never/$txz_name" --out "$plg" >/dev/null
"$REPO/scripts/lint-plg" "$plg"

step "fake Unraid host"
printf 'version="7.0.0"\n' >/etc/unraid-version
cat >/usr/local/emhttp/webGui/include/Wrappers.php <<'PHP'
<?php
function my_logger($message, $logger = 'plugin') {
  file_put_contents('/tmp/e2e/plugin-manager.log', "[$logger] $message\n", FILE_APPEND);
}
PHP
cat >/usr/local/emhttp/webGui/include/publish.php <<'PHP'
<?php
function publish() {}
PHP
printf '#!/bin/bash\necho "notify $*" >> /tmp/e2e/notify.log\n' >/usr/local/emhttp/webGui/scripts/notify
chmod 0755 /usr/local/emhttp/webGui/scripts/notify
install -m 0755 "$REPO/tests/vendor/unraid/plugin" /usr/local/sbin/plugin
# Any attempt to download fails loudly: these scenarios must not need the network.
printf '#!/bin/bash\necho "wget called: $*" >> /tmp/e2e/wget.log\nexit 4\n' >"$E2E/bin/wget"
chmod 0755 "$E2E/bin/wget"
export PATH="$E2E/bin:$PATH"
# logger has no syslog here; keep it quiet.
printf '#!/bin/bash\nexit 0\n' >"$E2E/bin/logger"
chmod 0755 "$E2E/bin/logger"

plugin() { php /usr/local/sbin/plugin "$@"; }
installed_pkg() {
  local n=0 f
  for f in /var/lib/pkgtools/packages/"$PLUGIN"-*; do
    [ -e "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

step "A: fresh install with the package cached on flash"
mkdir -p "/boot/config/plugins/$PLUGIN/pkg"
cp "$txz" "/boot/config/plugins/$PLUGIN/pkg/$txz_name"
printf 'DATA_DIR=""\nRESTORE_SESSIONS="yes"\n' >"/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"
plugin install "$plg" | tee "$E2E/install-A.log"
assert "plg registered in /var/log/plugins" test -L "/var/log/plugins/$PLUGIN.plg"
assert "plg copied to /boot/config/plugins" test -f "/boot/config/plugins/$PLUGIN.plg"
assert "package installed" test "$(installed_pkg)" = 1
assert "package scripts present and executable" test -x "/usr/local/emhttp/plugins/$PLUGIN/scripts/install-binary"
assert "install steps ran" grep -q "install-binary: not implemented yet" "$E2E/install-A.log"
assert_not "nothing was downloaded" test -e "$E2E/wget.log"
assert "cached package untouched" cmp -s "$txz" "/boot/config/plugins/$PLUGIN/pkg/$txz_name"

step "B: reboot with a valid cache"
rm -rf "/usr/local/emhttp/plugins/$PLUGIN" /var/lib/pkgtools /var/log/plugins/* /tmp/plugins/*
plugin install "/boot/config/plugins/$PLUGIN.plg" | tee "$E2E/install-B.log"
assert "plg registered again" test -L "/var/log/plugins/$PLUGIN.plg"
assert "package installed again" test "$(installed_pkg)" = 1
assert_not "still nothing downloaded" test -e "$E2E/wget.log"
assert_not "plg not in plugins-error" test -e "/boot/config/plugins-error/$PLUGIN.plg"

step "C: corrupt cache and no network"
rm -rf "/usr/local/emhttp/plugins/$PLUGIN" /var/lib/pkgtools /var/log/plugins/* /tmp/plugins/*
printf 'corrupt' >"/boot/config/plugins/$PLUGIN/pkg/$txz_name"
set +e
plugin install "/boot/config/plugins/$PLUGIN.plg" | tee "$E2E/install-C.log"
set -e
assert "download was attempted" test -e "$E2E/wget.log"
assert "install reported the failure" grep -q "download failure" "$E2E/install-C.log"
assert "plg moved to plugins-error" test -f "/boot/config/plugins-error/$PLUGIN.plg"
assert_not "plg not registered" test -e "/var/log/plugins/$PLUGIN.plg"
# restore for the next scenario
mv "/boot/config/plugins-error/$PLUGIN.plg" "/boot/config/plugins/$PLUGIN.plg"
cp "$txz" "/boot/config/plugins/$PLUGIN/pkg/$txz_name"
rm -f "$E2E/wget.log"
plugin install "/boot/config/plugins/$PLUGIN.plg" >/dev/null
assert "recovered after the cache was fixed" test -L "/var/log/plugins/$PLUGIN.plg"

step "D: remove"
plugin remove "$PLUGIN.plg" | tee "$E2E/remove.log"
assert "remove step ran" grep -q "remove: not implemented yet" "$E2E/remove.log"
assert "plg moved to plugins-removed" test -f "/boot/config/plugins-removed/$PLUGIN.plg"
assert_not "plg unregistered" test -e "/var/log/plugins/$PLUGIN.plg"
assert "cfg kept on flash" test -f "/boot/config/plugins/$PLUGIN/$PLUGIN.cfg"

step "E: fresh install from a LOCAL package, no cache"
rm -rf "/boot/config/plugins/$PLUGIN/pkg" "/usr/local/emhttp/plugins/$PLUGIN" /var/lib/pkgtools /var/log/plugins/* /tmp/plugins/*
sed "s#<URL>\"[^\"]*\"</URL>#<LOCAL>$txz</LOCAL>#" "$plg" >"$E2E/local.plg"
grep -q "<LOCAL>$txz</LOCAL>" "$E2E/local.plg" || fail "LOCAL substitution failed"
cp "$E2E/local.plg" "/tmp/plugins/$PLUGIN.plg"
plugin install "/tmp/plugins/$PLUGIN.plg" | tee "$E2E/install-E.log"
assert "LOCAL install registered" test -L "/var/log/plugins/$PLUGIN.plg"
assert "package cached on flash from LOCAL" test -f "/boot/config/plugins/$PLUGIN/pkg/$txz_name"
assert "package installed from LOCAL" test "$(installed_pkg)" = 1
assert_not "nothing downloaded" test -e "$E2E/wget.log"
plugin remove "$PLUGIN.plg" >/dev/null

printf '\ne2e-install: all scenarios passed\n'
