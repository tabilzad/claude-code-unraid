<?php
/* include/policy.php: the policy drop-in editor behind the settings page.
 * Validation, normalisation, the flash write (only when changed), removal,
 * and the install-policy run, against a stub under the test ROOT. */
declare(strict_types=1);

require_once plugin_src('include/actions.php');

function policy_root(): string
{
    $root = actions_root();
    $scripts = "$root/usr/local/emhttp/plugins/claude-code-unraid/scripts";
    if (!is_file("$scripts/install-policy")) {
        mkdir($scripts, 0755, true);
        $stub = <<<'SH'
#!/usr/bin/env bash
printf 'run %s\n' "$#" >>"${ROOT:?}/install-policy-calls"
echo "stub: policy rendered"
exit 0
SH;
        file_put_contents("$scripts/install-policy", $stub);
        chmod("$scripts/install-policy", 0755);
    }
    return $root;
}

function policy_calls(string $root): int
{
    $f = "$root/install-policy-calls";
    return is_file($f) ? count(file($f, FILE_IGNORE_NEW_LINES) ?: []) : 0;
}

function test_policy_validation_normalises_and_keeps_empty_objects(): void
{
    $r = ccu_validate_policy("  {\"permissions\":{\"allow\":[\"Bash(docker compose *)\",\"WebFetch(domain:docs.unraid.net)\"],\"ask\":[]},\"env\":{}}\n");
    assert_same(true, $r['ok'], implode(' ', $r['errors']));
    assert_same([], $r['notes']);
    $expected = "{\n    \"permissions\": {\n        \"allow\": [\n            \"Bash(docker compose *)\",\n            \"WebFetch(domain:docs.unraid.net)\"\n        ],\n        \"ask\": []\n    },\n    \"env\": {}\n}\n";
    assert_same($expected, $r['json']);
    // empty text and an empty object both mean "no drop-in"
    foreach (['', "  \n", '{}', " { } "] as $empty) {
        $r = ccu_validate_policy($empty);
        assert_same(true, $r['ok'], "empty form '$empty'");
        assert_same(null, $r['json'], "empty form '$empty'");
    }
}

function test_policy_validation_rejects_what_would_break_claude_code(): void
{
    $cases = [
        '{"permissions": {"allow": ["Bash(ls)"]' => 'not valid JSON',
        '["Bash(ls *)"]' => 'must be a JSON object',
        '"Bash(ls *)"' => 'must be a JSON object',
        '{"permissions": ["Bash(ls *)"]}' => '"permissions" must be an object',
        '{"permissions": {"allow": "Bash(ls *)"}}' => '"permissions.allow" must be a list',
        '{"permissions": {"deny": [1]}}' => '"permissions.deny" entry 1 is not a rule string',
        '{"permissions": {"ask": ["Bash(ls *)", ""]}}' => '"permissions.ask" entry 2 is not a rule string',
        "{\"permissions\": {\"allow\": [\"Bash(ls *)\\u0007\"]}}" => 'entry 1 is not a rule string',
    ];
    foreach ($cases as $input => $message) {
        $r = ccu_validate_policy($input);
        assert_same(false, $r['ok'], "accepted: $input");
        assert_same(null, $r['json']);
        assert_contains($message, implode("\n", $r['errors']), "message for $input");
    }
    $big = '{"permissions": {"allow": ["Bash(' . str_repeat('a', 70000) . ' *)"]}}';
    $r = ccu_validate_policy($big);
    assert_same(false, $r['ok']);
    assert_contains('larger than 64 KiB', implode("\n", $r['errors']));
}

function test_policy_validation_notes_locked_keys_but_accepts_them(): void
{
    $r = ccu_validate_policy('{"permissions": {"defaultMode": "acceptEdits", "disableBypassPermissionsMode": "allow", "allow": ["Bash(uptime)"]}, "disableAutoMode": "enable", "env": {"DISABLE_UPDATES": "0", "FOO": "bar"}, "cleanupPeriodDays": 3}');
    assert_same(true, $r['ok'], implode(' ', $r['errors']));
    $notes = implode("\n", $r['notes']);
    foreach (['permissions.defaultMode', 'permissions.disableBypassPermissionsMode', 'disableAutoMode', 'env.DISABLE_UPDATES', 'cleanupPeriodDays'] as $key) {
        assert_contains("$key is set by the plugin's baseline", $notes);
    }
    assert_not_contains('env.FOO', $notes);
    assert_same(5, count($r['notes']));
}

function test_policy_save_writes_only_on_change_and_applies_the_policy(): void
{
    $root = policy_root();
    $file = "$root/boot/config/plugins/claude-code-unraid/policy.d/webgui.json";
    @unlink($file);
    @unlink("$root/install-policy-calls");

    $r = ccu_run_action('policy-save', ['policy' => '{"permissions":{"allow":["Bash(docker compose *)"]}}']);
    assert_same(true, $r['ok'], json_encode($r));
    assert_same(true, $r['changed']);
    assert_true(is_file($file), 'drop-in written');
    assert_same("{\n    \"permissions\": {\n        \"allow\": [\n            \"Bash(docker compose *)\"\n        ]\n    }\n}\n", file_get_contents($file));
    assert_same(file_get_contents($file), ccu_policy_read());
    assert_same(1, policy_calls($root), 'install-policy ran once');
    $out = implode("\n", $r['output']);
    assert_contains('policy saved to /boot/config/plugins/claude-code-unraid/policy.d/webgui.json', $out);
    assert_contains('stub: policy rendered', $out);
    assert_contains('policy applied', $out);
    assert_same([], glob("$root/boot/config/plugins/claude-code-unraid/policy.d/.webgui.*") ?: []);

    // same content, differently formatted: no flash write, no install-policy run
    $r = ccu_run_action('policy-save', ['policy' => "{ \"permissions\": { \"allow\": [ \"Bash(docker compose *)\" ] } }\n\n"]);
    assert_same(true, $r['ok']);
    assert_same(false, $r['changed']);
    assert_contains('policy unchanged', implode("\n", $r['output']));
    assert_same(1, policy_calls($root), 'install-policy not run again');

    // invalid text leaves the file alone
    $r = ccu_run_action('policy-save', ['policy' => '{"permissions": {"allow": "Bash"}}']);
    assert_same(false, $r['ok']);
    assert_contains('"permissions.allow" must be a list', $r['error']);
    assert_contains('Bash(docker compose *)', file_get_contents($file));
    assert_same(1, policy_calls($root));

    // notes travel with the result
    $r = ccu_run_action('policy-save', ['policy' => '{"disableAutoMode": "enable", "permissions": {"allow": ["Bash(uptime)"]}}']);
    assert_same(true, $r['ok']);
    assert_contains("note: disableAutoMode is set by the plugin's baseline", implode("\n", $r['output']));
    assert_same(2, policy_calls($root));

    // empty text removes the drop-in and re-renders
    $r = ccu_run_action('policy-save', ['policy' => "  \n"]);
    assert_same(true, $r['ok']);
    assert_same(true, $r['changed']);
    assert_true(!is_file($file), 'drop-in removed');
    assert_contains('policy drop-in removed', implode("\n", $r['output']));
    assert_same(3, policy_calls($root));
    assert_same('', ccu_policy_read());
    $r = ccu_run_action('policy-save', ['policy' => '']);
    assert_same(true, $r['ok']);
    assert_same(false, $r['changed']);
    assert_same(3, policy_calls($root));
}

function test_policy_save_needs_the_text_and_exec_php_passes_it(): void
{
    $root = policy_root();
    $r = ccu_run_action('policy-save');
    assert_same(false, $r['ok']);
    assert_contains('policy text is missing', $r['error']);
    $r = ccu_run_action('policy-save', ['policy' => 42]);
    assert_same(false, $r['ok']);

    $runner = dirname(__DIR__) . '/helpers/run-exec.php';
    [$rc, $out] = run_cmd(['php', $runner, 'POST', 'policy-save', '{"permissions": {"allow": ["Bash(uptime)"]}}'], '', ['ROOT' => $root]);
    assert_same(0, $rc);
    $doc = json_decode($out, true, 8, JSON_THROW_ON_ERROR);
    assert_same(true, $doc['ok'], $out);
    assert_same('policy-save', $doc['action']);
    [, $out] = run_cmd(['php', $runner, 'POST', 'policy-save', 'not json'], '', ['ROOT' => $root]);
    $doc = json_decode($out, true, 8, JSON_THROW_ON_ERROR);
    assert_same(false, $doc['ok']);
    assert_contains('not valid JSON', $doc['error']);
    [, $out] = run_cmd(['php', $runner, 'POST', 'policy-save'], '', ['ROOT' => $root]);
    $doc = json_decode($out, true, 8, JSON_THROW_ON_ERROR);
    assert_same(false, $doc['ok']);
    @unlink("$root/boot/config/plugins/claude-code-unraid/policy.d/webgui.json");
}
