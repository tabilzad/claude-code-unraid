#!/bin/bash
# Stub Claude Code binary for the emulated host. Built into the fake release
# bucket with its version substituted for @VER@ (so each "release" has its own
# sha256). It behaves like the real thing where the plugin can tell:
#   --version / doctor      print and exit
#   SessionStart/SessionEnd it runs the plugin's session-hook with a payload
#                           shaped like Claude Code's, so the registry is real
#   --resume ID             resumes ID; STUB_FAIL_RESUME=1 makes it fail like
#                           a resume of an unknown session does
#   STUB_EXEC="cmd"         run a command and exit with its status (used to
#                           probe the read-only /boot from inside a session)
#   otherwise               idle until the fake tmux sends /exit or SIGTERM
set -u
ver="@VER@"
case "${1:-}" in
  --version)
    echo "stub claude $ver"
    exit 0
    ;;
  doctor)
    echo "stub doctor ok ($ver)"
    exit 0
    ;;
esac

hook="/usr/local/emhttp/plugins/claude-code-unraid/policy/session-hook"
sid=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[i]}" = --resume ]; then
    sid=${args[i + 1]:-}
  fi
done
source=startup
if [ -n "$sid" ]; then
  source=resume
  if [ "${STUB_FAIL_RESUME:-0}" = 1 ]; then
    echo "Failed to resume the conversation" >&2
    exit 1
  fi
else
  sid="stub-$(date +%s)-$$"
fi

payload() { # EVENT EXTRA
  printf '{"session_id":"%s","transcript_path":"%s/projects/x/%s.jsonl","cwd":"%s","hook_event_name":"%s",%s}' \
    "$sid" "${CLAUDE_CONFIG_DIR:-/tmp}" "$sid" "$PWD" "$1" "$2"
}
end_hook() { # REASON
  [ -x "$hook" ] && payload SessionEnd "\"reason\":\"$1\"" | "$hook"
}

[ -x "$hook" ] && payload SessionStart "\"source\":\"$source\"" | "$hook"
printf 'stub claude %s session %s cwd %s args:%s\n' "$ver" "$sid" "$PWD" "$*"

if [ -n "${STUB_EXEC:-}" ]; then
  bash -c "$STUB_EXEC"
  rc=$?
  end_hook other
  exit "$rc"
fi

trap 'end_hook other; exit 0' TERM
while :; do
  if grep -q '^/exit$' "${FAKE_TMUX_KEYS:-/dev/null}" 2>/dev/null; then
    end_hook prompt_input_exit
    exit 0
  fi
  sleep 0.2
done
