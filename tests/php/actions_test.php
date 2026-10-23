<?php
/* include/actions.php and include/exec.php: the action allowlist, fixed
 * commands, JSON shapes and method handling. A fake claude-unraid under a
 * temporary ROOT answers the helper calls. */
declare(strict_types=1);

require_once plugin_src('include/actions.php');

function actions_root(): string
{
    static $root = null;
    if ($root !== null) {
        return $root;
    }
    $root = temp_dir();
    mkdir("$root/usr/local/bin", 0755, true);
    mkdir("$root/var/log/claude-code-unraid", 0755, true);
    $fake = <<<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ROOT:?}/helper-calls"
case "$1 ${2:-}" in
  "status --json") printf '{"plugin_version":"2026.01.02.3","claude":{"version":"1.2.3","verified":true},"mode":"pool","sessions":["server|running|abc|t"]}\n' ;;
  "verify ") echo "verify: OK"; exit 0 ;;
  "stop --all") echo "claude-unraid: stopped 1 session(s): server" ;;
  "restore ") echo "restore started" >>"${ROOT:?}/restore-marker" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
SH;
    file_put_contents("$root/usr/local/bin/claude-unraid", $fake);
    chmod("$root/usr/local/bin/claude-unraid", 0755);
    putenv("ROOT=$root");
    return $root;
}

function test_unknown_and_injected_actions_are_rejected(): void
{
    actions_root();
    foreach (['', 'bogus', 'status; rm -rf /', 'verify && id', "log\n", 'STATUS', '../status', 'stop-all --timeout 1'] as $bad) {
        $r = ccu_run_action($bad);
        assert_same(false, $r['ok'], "action '$bad'");
        assert_same('unknown action', $r['error']);
    }
}

function test_status_action_returns_the_decoded_helper_output(): void
{
    actions_root();
    $r = ccu_run_action('status');
    assert_same(true, $r['ok']);
    assert_same('2026.01.02.3', $r['status']['plugin_version']);
    assert_same(true, $r['status']['claude']['verified']);
}

function test_verify_and_stop_all_run_fixed_commands(): void
{
    $root = actions_root();
    @unlink("$root/helper-calls");
    $r = ccu_run_action('verify');
    assert_same(true, $r['ok']);
    assert_contains('verify: OK', implode("\n", $r['output']));
    $r = ccu_run_action('stop-all');
    assert_same(true, $r['ok']);
    assert_contains('stopped 1 session', implode("\n", $r['output']));
    $calls = file_get_contents("$root/helper-calls");
    assert_same("verify\nstop --all --timeout 10\n", $calls);
}

function test_restore_runs_detached(): void
{
    $root = actions_root();
    @unlink("$root/restore-marker");
    $r = ccu_run_action('restore');
    assert_same(true, $r['ok']);
    assert_contains('background', implode(' ', $r['output']));
    usleep(500000);
    assert_true(is_file("$root/restore-marker"), 'restore ran');
}

function test_log_action_tails_the_install_log_and_strips_control_chars(): void
{
    $root = actions_root();
    $lines = [];
    for ($i = 1; $i <= 250; $i++) {
        $lines[] = "line $i";
    }
    $lines[] = "evil \x1b[31mred\x1b[0m \x07bell";
    file_put_contents("$root/var/log/claude-code-unraid/install.log", implode("\n", $lines) . "\n");
    $r = ccu_run_action('log');
    assert_same(true, $r['ok']);
    assert_same(200, count($r['lines']));
    assert_same('line 52', $r['lines'][0]);
    assert_same('evil [31mred[0m bell', $r['lines'][199]);
    unlink("$root/var/log/claude-code-unraid/install.log");
    $r = ccu_run_action('log');
    assert_same([], $r['lines']);
}

function test_exec_php_rejects_non_post_and_answers_json(): void
{
    $root = actions_root();
    $runner = dirname(__DIR__) . '/helpers/run-exec.php';
    [$rc, $out] = run_cmd(['php', $runner, 'GET', 'status'], '', ['ROOT' => $root]);
    assert_same(0, $rc);
    $doc = json_decode($out, true, 8, JSON_THROW_ON_ERROR);
    assert_same(false, $doc['ok']);
    assert_same('POST required', $doc['error']);
    [, $out] = run_cmd(['php', $runner, 'POST', 'status'], '', ['ROOT' => $root]);
    $doc = json_decode($out, true, 8, JSON_THROW_ON_ERROR);
    assert_same(true, $doc['ok']);
    assert_same('status', $doc['action']);
    [, $out] = run_cmd(['php', $runner, 'POST', 'nope; id'], '', ['ROOT' => $root]);
    $doc = json_decode($out, true, 8, JSON_THROW_ON_ERROR);
    assert_same(false, $doc['ok']);
    [, $out] = run_cmd(['php', $runner, 'POST'], '', ['ROOT' => $root]);
    $doc = json_decode($out, true, 8, JSON_THROW_ON_ERROR);
    assert_same(false, $doc['ok']);
}

function test_helper_bin_is_fixed_and_root_prefixed(): void
{
    $root = actions_root();
    assert_same("$root/usr/local/bin/claude-unraid", ccu_helper_bin());
    assert_same('&lt;b&gt;&quot;x&quot;&apos;', ccu_h('<b>"x"\''));
}

function test_restore_rotates_a_large_log(): void
{
    $root = actions_root();
    $log = "$root/var/log/claude-code-unraid/restore.log";
    file_put_contents($log, str_repeat('x', 600000));
    $r = ccu_run_action('restore');
    assert_same(true, $r['ok']);
    usleep(500000);
    clearstatcache();
    assert_true(is_file("$log.1"), 'large restore.log rotated to .1');
    assert_true(!is_file($log) || filesize($log) < 1000, 'a fresh restore.log was started');
    unlink("$log.1");
    @unlink($log);
}
