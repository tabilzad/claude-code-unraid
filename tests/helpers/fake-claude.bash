#!/usr/bin/env bash
# A fake `claude` launcher for the session tests. Records its arguments and
# the plugin's environment flags under FAKE_CLAUDE_DUMP, simulates a failed
# resume for ids that start with "fail-", exits on "/exit" from the fake tmux
# (unless FAKE_CLAUDE_STUBBORN=1, which also ignores SIGTERM) and otherwise
# idles like a TUI would.
set -u
dump="${FAKE_CLAUDE_DUMP:?}"
mkdir -p "$dump"
session="${FAKE_TMUX_SESSION:-none}"
printf '%s\n' "$*" >"$dump/$session.args"
env | grep -E '^CLAUDE_CODE_UNRAID_' | LC_ALL=C sort >"$dump/$session.env"
case " $* " in
  *" --resume fail-"*)
    echo "Failed to resume the conversation" >&2
    exit 1
    ;;
esac
if [ "${FAKE_CLAUDE_STUBBORN:-0}" = 1 ]; then
  trap '' TERM
fi
while :; do
  if [ "${FAKE_CLAUDE_STUBBORN:-0}" != 1 ] && grep -q '^/exit$' "${FAKE_TMUX_KEYS:-/dev/null}" 2>/dev/null; then
    exit 0
  fi
  sleep 0.2
done
