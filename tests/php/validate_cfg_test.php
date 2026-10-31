<?php
/* include/validate-cfg.php: the server-side validation behind the settings form. */
declare(strict_types=1);

require_once plugin_src('include/validate-cfg.php');

function ok_checker(): callable
{
    return static fn (string $path): array => ['valid' => true, 'reason' => ''];
}

function test_valid_form_is_normalised_and_saved(): void
{
    $r = ccu_validate_cfg([
        '#file' => 'claude-code-unraid/claude-code-unraid.cfg',
        'DATA_DIR' => '/mnt/cache/appdata/claude-code-unraid/',
        'RESTORE_SESSIONS' => 'Yes',
        'MAX_RESTORE' => '04',
        'CLEANUP_DAYS' => '30',
        'ALLOW_AUTO_MODE' => 'no',
        'ALLOW_BOOT_RW' => 'no',
        'REMOTE_CONTROL' => 'NO',
        'EVENT_TIMEOUT' => '20',
        'CHANNEL' => 'latest',
    ], ok_checker());
    assert_same(true, $r['save']);
    assert_same('/mnt/cache/appdata/claude-code-unraid', $r['post']['DATA_DIR']);
    assert_same('yes', $r['post']['RESTORE_SESSIONS']);
    assert_same('4', $r['post']['MAX_RESTORE']);
    assert_same('no', $r['post']['REMOTE_CONTROL']);
    assert_same('stable', $r['post']['CHANNEL']);
    assert_true(!array_key_exists('#file', $r['post']));
}

function test_unknown_keys_are_dropped_and_reported(): void
{
    $r = ccu_validate_cfg(['DATA_DIR' => '', 'EVIL' => 'x', 'PATH' => '/tmp'], ok_checker());
    assert_same(true, $r['save']);
    assert_same(['DATA_DIR' => ''], $r['post']);
    assert_contains("ignored unknown setting 'EVIL'", implode("\n", $r['messages']));
}

function test_bad_values_block_the_save(): void
{
    foreach ([
        ['RESTORE_SESSIONS' => 'maybe'],
        ['MAX_RESTORE' => '21'],
        ['MAX_RESTORE' => '-1'],
        ['CLEANUP_DAYS' => '0'],
        ['EVENT_TIMEOUT' => '4'],
        ['EVENT_TIMEOUT' => '10; rm'],
        ['DATA_DIR' => '/tmp/x'],
        ['DATA_DIR' => '/mnt/user/appdata/with space'],
        ['DATA_DIR' => '/mnt/user/appdata/x"y'],
        ['DATA_DIR' => '/mnt/user/../etc'],
        ['DATA_DIR' => '/mnt/cache/$(id)'],
    ] as $post) {
        $r = ccu_validate_cfg($post, ok_checker());
        assert_same(false, $r['save'], json_encode($post));
    }
}

function test_control_characters_are_stripped(): void
{
    $r = ccu_validate_cfg(['DATA_DIR' => "/mnt/cache/appdata/x\n"], ok_checker());
    assert_same(true, $r['save']);
    assert_same('/mnt/cache/appdata/x', $r['post']['DATA_DIR']);
}

function test_data_dir_check_results_are_honoured(): void
{
    $reject = static fn (string $p): array => ['valid' => false, 'reason' => 'creating /mnt/user/new would create a new share'];
    $r = ccu_validate_cfg(['DATA_DIR' => '/mnt/user/new'], $reject);
    assert_same(false, $r['save']);
    assert_contains('would create a new share', implode("\n", $r['messages']));

    $stopped = static fn (string $p): array => ['valid' => false, 'reason' => '/mnt/user is not mounted (array or pool not started)'];
    $r = ccu_validate_cfg(['DATA_DIR' => '/mnt/user/appdata/claude'], $stopped);
    assert_same(true, $r['save'], 'an unmounted array only defers the check');
    assert_contains('checked when the array starts', implode("\n", $r['messages']));

    $r = ccu_validate_cfg(['DATA_DIR' => ''], $reject);
    assert_same(true, $r['save'], 'empty means auto and is never checked');
}

function test_non_string_values_are_rejected(): void
{
    $r = ccu_validate_cfg(['DATA_DIR' => ['a' => 'b']], ok_checker());
    assert_same(false, $r['save']);
}

function test_managed_claude_md_is_a_yes_no_switch(): void
{
    $r = ccu_validate_cfg(['MANAGED_CLAUDE_MD' => 'No'], ok_checker());
    assert_same(true, $r['save']);
    assert_same('no', $r['post']['MANAGED_CLAUDE_MD']);
    $r = ccu_validate_cfg(['MANAGED_CLAUDE_MD' => 'sometimes'], ok_checker());
    assert_same(false, $r['save']);
    assert_contains('MANAGED_CLAUDE_MD must be yes or no', implode("\n", $r['messages']));
}
