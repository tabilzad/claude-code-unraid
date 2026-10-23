#!/usr/bin/env bash
# A fake tmux for the session tests: enough of new-session, has-session,
# list-panes, send-keys, kill-session, list-sessions and attach-session to
# drive claude-unraid without a terminal. Sessions are directories under
# FAKE_TMUX_STATE; "send-keys" appends lines to <session>/keys, which the fake
# launcher polls for "/exit".
set -u
state="${FAKE_TMUX_STATE:?}"
mkdir -p "$state"
if [ "${1:-}" = -S ]; then shift 2; fi
cmd=${1:-}
shift || true

name_of() {
  local t=$1
  t=${t#=}
  t=${t%:}
  printf '%s' "$t"
}
alive() { [ -f "$state/$1/pid" ] && kill -0 "$(cat "$state/$1/pid")" 2>/dev/null; }

case "$cmd" in
  new-session)
    name="" dir=""
    cmdv=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -d) ;;
        -s)
          name=$2
          shift
          ;;
        -c)
          dir=$2
          shift
          ;;
        --)
          shift
          cmdv=("$@")
          break
          ;;
      esac
      shift
    done
    [ -n "$name" ] || exit 1
    alive "$name" && exit 1
    mkdir -p "$state/$name"
    : >"$state/$name/keys"
    (
      cd "$dir" || exit 1
      FAKE_TMUX_SESSION="$name" FAKE_TMUX_KEYS="$state/$name/keys" setsid "${cmdv[@]}" </dev/null >"$state/$name/out" 2>&1 &
      echo $! >"$state/$name/pid"
    )
    ;;
  has-session)
    n=$(name_of "$2")
    alive "$n"
    ;;
  list-panes)
    n=$(name_of "$2")
    alive "$n" && cat "$state/$n/pid"
    ;;
  send-keys)
    n=$(name_of "$2")
    shift 2
    [ "${1:-}" = -l ] && shift
    printf '%s\n' "$*" >>"$state/$n/keys"
    ;;
  kill-session)
    n=$(name_of "$2")
    [ -f "$state/$n/pid" ] && kill -9 "$(cat "$state/$n/pid")" 2>/dev/null
    rm -rf "${state:?}/${n:?}"
    ;;
  list-sessions)
    for d in "$state"/*/; do
      [ -d "$d" ] || continue
      n=$(basename "$d")
      alive "$n" && echo "$n"
    done
    ;;
  attach-session)
    n=$(name_of "$2")
    alive "$n" && echo "attached $n"
    ;;
  -V) echo "tmux 3.2a" ;;
  *)
    echo "fake tmux: unsupported: $cmd $*" >&2
    exit 1
    ;;
esac
