<?php
/* include/ui.php: the presentation helpers behind the settings page. */
declare(strict_types=1);

require_once plugin_src('include/ui.php');

function test_theme_is_normalised_to_one_of_four(): void
{
    assert_same('black', ccu_theme('black'));
    assert_same('white', ccu_theme('white-bannered'));
    assert_same('azure', ccu_theme(' Azure '));
    assert_same('gray', ccu_theme('gray'));
    assert_same('gray', ccu_theme('grey'));
    assert_same('black', ccu_theme(''));
    assert_same('black', ccu_theme(null));
    assert_same('black', ccu_theme('neon'));
}

function test_badge_escapes_and_validates_the_tone(): void
{
    assert_same('<span class="ccu-badge" data-tone="ok">pool</span>', ccu_badge('pool', 'ok'));
    assert_same('<span class="ccu-badge" data-tone="neutral">x</span>', ccu_badge('x', 'purple" onclick="x'));
    assert_contains('&lt;b&gt;', ccu_badge('<b>', 'warn'));
    assert_not_contains('<b>', ccu_badge('<b>', 'warn'));
    assert_same('<span class="ccu-badge" data-tone="ok">yes</span>', ccu_yesno_badge(true));
    assert_same('<span class="ccu-badge" data-tone="ok">yes</span>', ccu_yesno_badge('yes'));
    assert_same('<span class="ccu-badge" data-tone="neutral">no</span>', ccu_yesno_badge(false));
    assert_same('<span class="ccu-badge" data-tone="bad">no</span>', ccu_yesno_badge('no', true));
}

function test_icons_are_constant_svg_or_empty(): void
{
    $svg = ccu_icon('shield');
    assert_contains('<svg class="ccu-icon"', $svg);
    assert_contains('aria-hidden="true"', $svg);
    assert_same('', ccu_icon('no-such-icon'));
    assert_same('', ccu_icon('<script>'));
}

function test_policy_rule_count(): void
{
    assert_same(null, ccu_policy_rule_count(''));
    assert_same(null, ccu_policy_rule_count("  \n"));
    assert_same(null, ccu_policy_rule_count('{'));
    assert_same(null, ccu_policy_rule_count('"a string"'));
    assert_same(0, ccu_policy_rule_count('{}'));
    assert_same(0, ccu_policy_rule_count('{"permissions": "no"}'));
    assert_same(3, ccu_policy_rule_count('{"permissions": {"allow": ["Bash(git *)", "Bash(ls)"], "deny": ["Read(./.env)"], "ask": "x"}}'));
}

function test_asset_version_is_mtime_or_dev(): void
{
    assert_same('dev', ccu_asset_version('/nonexistent/claude-code-unraid.css'));
    $tmp = tempnam(sys_get_temp_dir(), 'ccu');
    try {
        touch($tmp, 1700000000);
        assert_same('1700000000', ccu_asset_version($tmp));
    } finally {
        unlink($tmp);
    }
}
