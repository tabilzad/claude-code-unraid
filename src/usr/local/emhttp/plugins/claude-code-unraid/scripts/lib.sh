#!/bin/bash
# lib.sh: functions and paths shared by every script of the plugin.
#
# Source it (never execute it):
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Every absolute host path is prefixed with ${ROOT:-} so that the test suite
# can point the scripts at a fake root (CLAUDE.md, "ROOT prefix"). Host tools
# (logger, notify, flock, timeout, curl) are looked up at run time so the
# fixtures can stub them.
#
# Test mode (CCU_TEST_MODE=1) unlocks a few overrides that production never
# honours; each is documented where it is read.
#
# shellcheck disable=SC2034 # sourced library: its variables are read by the scripts that source it

[ -n "${CCU_LIB_LOADED:-}" ] && return 0
CCU_LIB_LOADED=1

PLUGIN=claude-code-unraid
PLUGIN_TITLE="Claude Code"
ROOT=${ROOT:-}

FLASH_DIR="$ROOT/boot/config/plugins/$PLUGIN"
EMHTTP_DIR="$ROOT/usr/local/emhttp/plugins/$PLUGIN"
LIB_DIR="$ROOT/usr/local/lib/$PLUGIN"
RUN_DIR="$ROOT/run/$PLUGIN"
LOG_DIR="$ROOT/var/log/$PLUGIN"
ETC_CLAUDE="$ROOT/etc/claude-code"
POLICY_DIR="$ETC_CLAUDE/managed-settings.d"
CFG_FILE="$FLASH_DIR/$PLUGIN.cfg"
BIN_LAUNCHER="$ROOT/usr/local/bin/claude"
BIN_HELPER="$ROOT/usr/local/bin/claude-unraid"
NOTIFY_BIN="$ROOT/usr/local/emhttp/webGui/scripts/notify"
VAR_INI="$ROOT/var/local/emhttp/var.ini"
DISKS_INI="$ROOT/var/local/emhttp/disks.ini"
DOCKER_CFG="$ROOT/boot/config/docker.cfg"
BINARY_STATE="$RUN_DIR/binary.state"
TMUX_STATE="$RUN_DIR/tmux.state"
MODE_FILE="$RUN_DIR/mode"
INSTALL_LOG="$LOG_DIR/install.log"
LOG_MAX_BYTES=524288

# default.cfg ships next to the scripts directory; in the test suite the
# scripts run from the source tree, so resolve it relative to this file.
CCU_LIB_DIR_SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_CFG="$CCU_LIB_DIR_SELF/../default.cfg"

test_mode=0
[ "${CCU_TEST_MODE:-0}" = 1 ] && test_mode=1

# ---------------------------------------------------------------------------
# Logging and notifications
# ---------------------------------------------------------------------------

# log LEVEL MESSAGE...   LEVEL: info|notice|warning|err
#   Appends to the bounded plugin log and forwards to syslog via logger.
#   Never fails and never prints secrets (callers must not pass any).
log() {
  local level=$1
  shift
  local msg="$*" ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if mkdir -p "$LOG_DIR" 2>/dev/null; then
    if [ -f "$INSTALL_LOG" ] && [ "$(stat -c %s "$INSTALL_LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
      mv -f "$INSTALL_LOG" "$INSTALL_LOG.1" 2>/dev/null || true
    fi
    printf '%s [%s] %s: %s\n' "$ts" "$level" "${CCU_SCRIPT_NAME:-${0##*/}}" "$msg" >>"$INSTALL_LOG" 2>/dev/null || true
  fi
  logger -t "$PLUGIN" -p "user.$level" -- "${CCU_SCRIPT_NAME:-${0##*/}}: $msg" 2>/dev/null || true
  if [ "$level" = err ] || [ "$level" = warning ]; then
    printf '%s: %s\n' "$PLUGIN" "$msg" >&2
  fi
}

# notify IMPORTANCE SUBJECT DESCRIPTION   IMPORTANCE: normal|warning|alert
#   Raises an Unraid notification when the notify script exists. No-op otherwise.
notify() {
  local importance=$1 subject=$2 description=$3
  [ -x "$NOTIFY_BIN" ] || return 0
  "$NOTIFY_BIN" -e "$PLUGIN_TITLE" -s "$subject" -d "$description" -i "$importance" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Configuration (KEY="value" files; never sourced)
# ---------------------------------------------------------------------------

# cfg_read_file FILE KEY: print the value of the last KEY= line, quotes stripped.
cfg_read_file() {
  local file=$1 key=$2 line value found=1
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      "$key="*) ;;
      *) continue ;;
    esac
    value=${line#"$key="}
    # A value that starts with a double quote ends at the next double quote,
    # like PHP's parse_ini_file; anything after it is ignored.
    if [ "${value#\"}" != "$value" ]; then
      value=${value#\"}
      value=${value%%\"*}
    fi
    found=0
    CFG_VALUE=$value
  done <"$file"
  [ "$found" = 0 ] || return 1
  printf '%s' "$CFG_VALUE"
}

# cfg_get KEY [DEFAULT]
#   The user cfg on flash overrides default.cfg; DEFAULT is the last resort.
#   Values with control characters are rejected (the default is used instead),
#   so a hand-edited cfg can never inject a newline into a command.
cfg_get() {
  local key=$1 default=${2:-} value
  if ! [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    printf '%s' "$default"
    return 0
  fi
  if value=$(cfg_read_file "$CFG_FILE" "$key") || value=$(cfg_read_file "$DEFAULT_CFG" "$key"); then
    if [[ "$value" =~ [[:cntrl:]] ]]; then
      log warning "ignoring $key in $CFG_FILE: control characters are not allowed"
      value=$default
    fi
    printf '%s' "$value"
    return 0
  fi
  printf '%s' "$default"
}

# cfg_bool KEY [DEFAULT yes|no]: prints yes or no
cfg_bool() {
  local v
  v=$(cfg_get "$1" "${2:-no}")
  case "${v,,}" in
    yes | true | 1 | on) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}

# ini_get FILE KEY: value of KEY="..." in an emhttp ini file (first section-less
# match or any section), quotes stripped. Used for var.ini.
ini_get() {
  local file=$1 key=$2 line value
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      "$key="*) ;;
      *) continue ;;
    esac
    value=${line#"$key="}
    value=${value#\"}
    value=${value%\"}
    printf '%s' "$value"
    return 0
  done <"$file"
  return 1
}

# ini_section_get FILE SECTION KEY: value of KEY inside ["SECTION"] (disks.ini).
ini_section_get() {
  local file=$1 section=$2 key=$3 line in=0 value
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      "[\"$section\"]" | "[$section]") in=1 ;;
      "["*) in=0 ;;
      "$key="*)
        if [ "$in" = 1 ]; then
          value=${line#"$key="}
          value=${value#\"}
          value=${value%\"}
          printf '%s' "$value"
          return 0
        fi
        ;;
    esac
  done <"$file"
  return 1
}

# array_state: STARTED, STOPPED, ... from var.ini (UNKNOWN when unreadable)
array_state() {
  ini_get "$VAR_INI" mdState 2>/dev/null || printf 'UNKNOWN'
}

# ---------------------------------------------------------------------------
# Files, locks, timeouts
# ---------------------------------------------------------------------------

# atomic_write PATH MODE  (content on stdin)
#   Writes to a temp file in the same directory, sets MODE, renames over PATH.
atomic_write() {
  local path=$1 mode=$2 dir tmp
  dir=$(dirname -- "$path")
  mkdir -p -- "$dir"
  tmp=$(mktemp -- "$dir/.$(basename -- "$path").XXXXXXXX") || return 1
  if cat >"$tmp" && chmod "$mode" "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# with_lock LOCKFILE TIMEOUT_SECONDS COMMAND...
#   Runs COMMAND under an exclusive flock. Fails (status 75) when the lock
#   cannot be taken within the timeout.
with_lock() {
  local lockfile=$1 timeout=$2
  shift 2
  mkdir -p -- "$(dirname -- "$lockfile")"
  (
    exec 9>>"$lockfile"
    if ! flock -w "$timeout" 9; then
      log warning "could not take lock $lockfile within ${timeout}s"
      exit 75
    fi
    "$@"
  )
}

# run_with_timeout SECONDS COMMAND...: SIGTERM at SECONDS, SIGKILL 3 s later.
run_with_timeout() {
  local secs=$1
  shift
  timeout -k 3 "$secs" "$@"
}

# sha256_of FILE
sha256_of() { sha256sum -- "$1" | cut -d' ' -f1; }

# sha256_eq FILE EXPECTED
sha256_eq() {
  local actual
  [ -f "$1" ] || return 1
  actual=$(sha256_of "$1") || return 1
  [ "$actual" = "${2,,}" ]
}

# free_kb PATH: free space in KiB on the filesystem holding PATH.
#   CCU_FAKE_FREE_KB overrides it in test mode only.
free_kb() {
  if [ "$test_mode" = 1 ] && [ -n "${CCU_FAKE_FREE_KB:-}" ]; then
    printf '%s' "$CCU_FAKE_FREE_KB"
    return 0
  fi
  df -Pk -- "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# state_write FILE KEY=VALUE...: a small KEY=VALUE state file in RUN_DIR
state_write() {
  local file=$1
  shift
  mkdir -p -- "$RUN_DIR"
  printf '%s\n' "$@" | atomic_write "$file" 0644
}

# state_get FILE KEY
state_get() {
  [ -r "$1" ] || return 1
  sed -n "s/^$2=//p" -- "$1" | head -n1
}

# is_regular_nonlink PATH: true for a regular file that is not a symlink
is_regular_nonlink() { [ -f "$1" ] && [ ! -L "$1" ]; }

# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------

# url_allowed URL EXPECTED_URL
#   Production: URL must equal EXPECTED_URL exactly. Test mode additionally
#   accepts file:/// and http://127.0.0.1 URLs with the same basename.
url_allowed() {
  local url=$1 expected=$2
  [ "$url" = "$expected" ] && return 0
  if [ "$test_mode" = 1 ]; then
    case "$url" in
      file:///* | http://127.0.0.1:* | http://127.0.0.1/*)
        [ "${url##*/}" = "${expected##*/}" ] && return 0
        ;;
    esac
  fi
  return 1
}

# download URL OUT SIZE_BYTES
#   curl with TLS 1.2+, https only (file:// and local http in test mode), three
#   retries and a timeout scaled to the size (assumes at least 256 KiB/s).
#   Redirects: up to three, to https only, unless CCU_DOWNLOAD_REDIRECTS=any
#   (the Slackware redirector may hand out http mirrors; the pinned sha256 is
#   what guarantees integrity there). Falls back to wget when curl is missing
#   (or CCU_FORCE_WGET=1 in test mode).
download() {
  local url=$1 out=$2 size=${3:-} max_time proto='=https' redir='=https'
  [[ "$size" =~ ^[0-9]+$ ]] || size=314572800
  max_time=$((size / 262144 + 120))
  case "$url" in
    file:///*) proto='=file' ;;
    http://127.0.0.1*) proto='=http' ;;
  esac
  [ "${CCU_DOWNLOAD_REDIRECTS:-strict}" = any ] && redir='=https,http'
  if command -v curl >/dev/null 2>&1 && ! { [ "$test_mode" = 1 ] && [ "${CCU_FORCE_WGET:-0}" = 1 ]; }; then
    curl --fail --silent --show-error --proto "$proto" --proto-redir "$redir" --tlsv1.2 \
      --location --max-redirs 3 \
      --retry 3 --retry-delay 3 --connect-timeout 20 --max-time "$max_time" \
      --output "$out" -- "$url"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    local -a wget_opts=(--quiet --tries=3 --timeout=20 --max-redirect=3)
    case "$url" in
      https://*)
        wget_opts+=(--secure-protocol=TLSv1_2)
        [ "$redir" = '=https' ] && wget_opts+=(--https-only)
        ;;
    esac
    run_with_timeout "$max_time" wget "${wget_opts[@]}" -O "$out" -- "$url"
    return $?
  fi
  log err "neither curl nor wget is available"
  return 127
}

# fetch_verified NAME URL SHA256 SIZE CACHE_PATH
#   Makes CACHE_PATH hold the verified artifact: reuses it when its sha256
#   matches, otherwise checks free space, downloads to RUN_DIR, verifies and
#   moves it there. Writes CACHE_PATH.sha256 next to it so a later boot can
#   trust the cached copy of an older version. Sets FETCH_SOURCE (cache|download)
#   on success and FETCH_ERROR on failure.
fetch_verified() {
  local name=$1 url=$2 sha=$3 size=$4 cache=$5
  local cache_dir tmp need_kb have_kb
  FETCH_SOURCE=""
  FETCH_ERROR=""
  cache_dir=$(dirname -- "$cache")
  mkdir -p -- "$cache_dir" "$RUN_DIR"

  if [ -e "$cache" ] && ! is_regular_nonlink "$cache"; then
    FETCH_ERROR="$cache is not a regular file; refusing to use it"
    return 1
  fi
  if is_regular_nonlink "$cache"; then
    if sha256_eq "$cache" "$sha"; then
      printf '%s  %s\n' "$sha" "$(basename -- "$cache")" >"$cache.sha256" 2>/dev/null || true
      FETCH_SOURCE=cache
      return 0
    fi
    log warning "$name: cached copy at $cache fails verification; discarding it"
    rm -f -- "$cache" "$cache.sha256"
  fi

  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ]; then
    need_kb=$((size * 12 / 10 / 1024 + 1))
    have_kb=$(free_kb "$cache_dir")
    if [[ "$have_kb" =~ ^[0-9]+$ ]] && [ "$have_kb" -lt "$need_kb" ]; then
      FETCH_ERROR="not enough free space on $(dirname -- "$cache_dir"): need ${need_kb} KiB (1.2 x the download), have ${have_kb} KiB"
      return 1
    fi
  fi

  tmp=$(mktemp -- "$RUN_DIR/dl.XXXXXXXX") || {
    FETCH_ERROR="cannot create a temporary file under $RUN_DIR"
    return 1
  }
  log info "$name: downloading $url"
  if ! download "$url" "$tmp" "$size"; then
    rm -f -- "$tmp"
    FETCH_ERROR="download failed: $url"
    return 1
  fi
  if ! sha256_eq "$tmp" "$sha"; then
    local got
    got=$(sha256_of "$tmp" 2>/dev/null || echo unknown)
    rm -f -- "$tmp"
    FETCH_ERROR="sha256 mismatch for $url: expected $sha, got $got"
    return 1
  fi
  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && [ "$(stat -c %s -- "$tmp")" != "$size" ]; then
    rm -f -- "$tmp"
    FETCH_ERROR="size mismatch for $url"
    return 1
  fi
  if ! mv -f -- "$tmp" "$cache"; then
    rm -f -- "$tmp"
    FETCH_ERROR="cannot write $cache"
    return 1
  fi
  if ! sha256_eq "$cache" "$sha"; then
    rm -f -- "$cache"
    FETCH_ERROR="the copy written to $cache_dir does not verify (bad flash drive?)"
    return 1
  fi
  printf '%s  %s\n' "$sha" "$(basename -- "$cache")" >"$cache.sha256" 2>/dev/null || true
  FETCH_SOURCE=download
  return 0
}

# install_ram_copy SRC DEST SHA256 MODE
#   Copies a verified file into RAM through a temp name, verifies the copy and
#   renames it over DEST. Refuses when DEST exists and is not a regular file.
install_ram_copy() {
  local src=$1 dest=$2 sha=$3 mode=$4 dir tmp
  dir=$(dirname -- "$dest")
  mkdir -p -- "$dir"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if ! is_regular_nonlink "$dest"; then
      INSTALL_ERROR="$dest exists and is not a regular file; refusing to replace it"
      return 1
    fi
    if sha256_eq "$dest" "$sha"; then
      chmod "$mode" -- "$dest" 2>/dev/null || true
      return 0
    fi
  fi
  tmp=$(mktemp -- "$dir/.$(basename -- "$dest").XXXXXXXX") || {
    INSTALL_ERROR="cannot create a temporary file under $dir"
    return 1
  }
  if ! cp -- "$src" "$tmp" || ! chmod "$mode" -- "$tmp"; then
    rm -f -- "$tmp"
    INSTALL_ERROR="cannot copy to $dir"
    return 1
  fi
  if ! sha256_eq "$tmp" "$sha"; then
    rm -f -- "$tmp"
    INSTALL_ERROR="the RAM copy of $(basename -- "$dest") does not verify"
    return 1
  fi
  mv -f -- "$tmp" "$dest"
}

# prune_cache DIR PREFIX KEEP_NAME
#   Keeps KEEP_NAME and the most recently modified other PREFIX* file (plus
#   their .sha256 sidecars); deletes the rest.
prune_cache() {
  local dir=$1 prefix=$2 keep=$3 f previous=""
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *.sha256) continue ;; esac
    [ "$f" = "$keep" ] && continue
    if [ -z "$previous" ]; then
      previous=$f
      continue
    fi
    rm -f -- "$dir/$f" "$dir/$f.sha256"
    log info "pruned old cached file $f"
  done < <(cd "$dir" && ls -1t -- "$prefix"* 2>/dev/null)
}
