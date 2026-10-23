#!/bin/bash
# event-lib.sh: the frame every array event handler runs in (SPEC section 8).
#
# emhttpd blocks until an event script returns, so each handler:
#   - runs its body under `timeout EVENT_TIMEOUT` (cfg, default 20 s, clamped
#     to 5..120) with SIGKILL three seconds after the SIGTERM;
#   - takes /run/<plugin>/event.lock with a 5 s wait, so two events never
#     interleave their mode switches;
#   - logs one start line and one end line with the duration;
#   - always exits 0: emhttpd ignores the status, and a non-zero status would
#     only confuse whoever reads the syslog.
#
# Usage in a handler:
#   . "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
#   . "$(dirname "${BASH_SOURCE[0]}")/../scripts/event-lib.sh"
#   event_body() { ...; }
#   run_event "$@"
#
# The timeout needs a process to kill, so run_event re-executes the handler
# with --body; that inner invocation takes the lock and runs event_body.
#
# shellcheck disable=SC2034 # sourced library: PROC_DIR is read by the handlers

PROC_DIR=/proc
if [ "${CCU_TEST_MODE:-0}" = 1 ] && [ -n "${CCU_PROC_DIR:-}" ]; then
  PROC_DIR=$CCU_PROC_DIR
fi
EVENT_LOCK="$RUN_DIR/event.lock"
SESSIONS_DIR="$RUN_DIR/sessions"

event_timeout() {
  local t
  t=$(cfg_get EVENT_TIMEOUT 20)
  [[ "$t" =~ ^[0-9]+$ ]] || t=20
  [ "$t" -ge 5 ] || t=5
  [ "$t" -le 120 ] || t=120
  printf '%s' "$t"
}

# run_event [--body] ARGS...
run_event() {
  local name=${CCU_EVENT_NAME:?}
  if [ "${1:-}" = --body ]; then
    shift
    with_lock "$EVENT_LOCK" 5 event_body "$@"
    exit $?
  fi
  mkdir -p -- "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true
  local start rc=0 limit
  start=$(date +%s)
  limit=$(event_timeout)
  log info "$name: start (timeout ${limit}s)"
  run_with_timeout "$limit" "$0" --body "$@" || rc=$?
  case "$rc" in
    0) ;;
    124 | 137) log warning "$name: body did not finish within ${limit}s and was stopped" ;;
    75) log warning "$name: another event handler held the lock for more than 5s; skipped" ;;
    *) log warning "$name: body exited with status $rc" ;;
  esac
  log info "$name: done in $(($(date +%s) - start))s"
  exit 0
}

# supervised_pids: PIDs recorded by the session supervisor, alive or not
supervised_pids() {
  local f pid
  for f in "$SESSIONS_DIR"/*.pid; do
    [ -f "$f" ] || continue
    pid=$(tr -cd '0-9' <"$f")
    [ -n "$pid" ] && printf '%s\n' "$pid"
  done
}

# pid_touches PID PREFIX: the process's cwd or one of its open files (first
# 256 descriptors) is under PREFIX (a real path, ROOT included when relevant)
pid_touches() {
  local pid=$1 prefix=$2 target n=0 fd
  target=$(readlink "$PROC_DIR/$pid/cwd" 2>/dev/null) || target=""
  case "$target" in
    "$prefix" | "$prefix"/*) return 0 ;;
  esac
  for fd in "$PROC_DIR/$pid"/fd/*; do
    [ -e "$fd" ] || [ -L "$fd" ] || continue
    n=$((n + 1))
    [ "$n" -le 256 ] || break
    target=$(readlink "$fd" 2>/dev/null) || continue
    case "$target" in
      "$prefix" | "$prefix"/*) return 0 ;;
    esac
  done
  return 1
}

# claude_pids: PIDs whose executable is the plugin's Claude binary
claude_pids() {
  local d exe pid
  for d in "$PROC_DIR"/[0-9]*; do
    pid=${d##*/}
    exe=$(readlink "$d/exe" 2>/dev/null) || continue
    case "$exe" in
      */usr/local/lib/"$PLUGIN"/claude-*) printf '%s\n' "$pid" ;;
    esac
  done
}
