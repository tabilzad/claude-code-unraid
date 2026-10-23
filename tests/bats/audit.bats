#!/usr/bin/env bats
# policy/audit: one syslog line per tool call, redacted and truncated, never
# the tool output, never a failure.

load '../helpers/fixtures'

AUDIT="$PLUGIN_SRC/policy/audit"
HI="$REPO_ROOT/tests/helpers/hook-input.php"

setup() {
  make_fakeroot
  export CCU_TEST_MODE=1
}

audit_bash() { # COMMAND
  php "$HI" post Bash "command=$1" | php "$AUDIT"
}

# the logger stub records with %q; unescape for readable assertions
logged() { calls logger | sed 's/\\\(.\)/\1/g'; }

@test "a Bash call is logged with session, cwd, tool and the command" {
  run audit_bash 'smartctl -a /dev/sdb'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_contains "$(logged)" "-t claude-code-unraid-audit -- session=sess-0123456789abcdef cwd=/data/work/server tool=Bash cmd=smartctl -a /dev/sdb"
  assert_not_contains "$(logged)" "SECRET OUTPUT"
}

@test "obvious secrets are redacted" {
  local l
  for cmd in \
    'mysql --password=hunter2 -e "show databases"' \
    'curl -u admin --password hunter2 https://x' \
    'export API_KEY=hunter2key; run' \
    'TOKEN=hunter2token ./deploy' \
    'curl -H "Authorization: Bearer hunter2bearer" https://x' \
    'curl -H "Authorization: Basic hunter2basic" https://x' \
    'aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE' \
    'export ANTHROPIC_API_KEY=sk-ant-api03-hunter2hunter2hunter2' \
    'echo sk-proj-hunter2hunter2hunter2hunter2 > key' \
    'git push https://user:hunter2pw@github.com/x/y' \
    'export GITHUB_TOKEN=ghp_hunter2hunter2hunter2hunter2' \
    'SLACK=xoxb-hunter2-hunter2-hunter2 ./bot' \
    'cat secret: hunter2secret' \
    'password: hunter2colon'; do
    : >"$FAKEROOT/calls.log"
    audit_bash "$cmd"
    l=$(logged)
    assert_not_contains "$l" "hunter2"
    assert_not_contains "$l" "AKIAIOSFODNN7EXAMPLE"
    assert_contains "$l" "redacted"
  done
}

@test "non-secret text that only looks similar is kept" {
  audit_bash 'grep -r "token bucket" /etc/nginx; ls /mnt/user/Passwords-Archive'
  assert_contains "$(logged)" 'grep -r "token bucket" /etc/nginx; ls /mnt/user/Passwords-Archive'
}

@test "long commands are truncated to 300 characters" {
  local long
  long=$(head -c 500 /dev/zero | tr '\0' 'a')
  audit_bash "echo $long"
  local l
  l=$(logged)
  assert_contains "$l" "...[+205 chars]"
  printf -v aaa '%*s' 295 ''
  aaa=${aaa// /a}
  assert_contains "$l" "cmd=echo ${aaa}...[+205 chars]"
}

@test "control characters never reach the log line" {
  audit_bash $'echo a\nrm -rf /tmp/x\r\tdone'
  local l
  l=$(logged)
  assert_contains "$l" "cmd=echo a rm -rf /tmp/x done"
  [ "$(grep -c '' "$FAKEROOT/calls.log")" -eq 1 ]
}

@test "file tools log the path, not the content" {
  php "$HI" post Write "file_path=/mnt/user/appdata/x/notes.md" "content=THIS IS CONTENT" | php "$AUDIT"
  assert_contains "$(logged)" "tool=Write path=/mnt/user/appdata/x/notes.md"
  assert_not_contains "$(logged)" "THIS IS CONTENT"
  : >"$FAKEROOT/calls.log"
  php "$HI" post Read "file_path=/etc/hosts" | php "$AUDIT"
  assert_contains "$(logged)" "tool=Read path=/etc/hosts"
  : >"$FAKEROOT/calls.log"
  php "$HI" post WebFetch "url=https://example.com/a" | php "$AUDIT"
  assert_contains "$(logged)" "tool=WebFetch path=https://example.com/a"
}

@test "bad input and a missing logger never fail the hook" {
  run bash -c "printf 'nope' | php '$AUDIT'"
  [ "$status" -eq 0 ]
  [ -z "$(calls logger)" ]
  run bash -c "printf '' | php '$AUDIT'"
  [ "$status" -eq 0 ]
  rm "$FAKEROOT/stubs/bin/logger"
  run bash -c "PATH='$FAKEROOT/stubs/bin' php '$HI' post Bash command=ls | PATH='$FAKEROOT/stubs/bin:/usr/local/bin:/usr/bin:/bin' php '$AUDIT'"
  [ "$status" -eq 0 ]
}

@test "session ids and tool names are sanitised" {
  run bash -c "printf '{\"session_id\":\"abc;rm -rf /\",\"cwd\":\"/x\",\"tool_name\":\"Bash\$(id)\",\"tool_input\":{\"command\":\"ls\"}}' | php '$AUDIT'"
  [ "$status" -eq 0 ]
  assert_contains "$(logged)" "session=abcrm-rf cwd=/x tool=Bashid"
}
