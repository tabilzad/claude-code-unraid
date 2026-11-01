<?php
/* ClaudeCode.page: the settings page rendered against a fake helper, through
 * tests/helpers/render-page.php (one PHP process per render, like the WebGUI). */
declare(strict_types=1);

function page_root(): string
{
    static $root = null;
    if ($root !== null) {
        return $root;
    }
    $root = temp_dir();
    mkdir("$root/usr/local/bin", 0755, true);
    mkdir("$root/boot/config/plugins/claude-code-unraid/policy.d", 0755, true);
    $fake = <<<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "status --json") [ -f "${ROOT:?}/status.json" ] || exit 1; cat "$ROOT/status.json" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
SH;
    file_put_contents("$root/usr/local/bin/claude-unraid", $fake);
    chmod("$root/usr/local/bin/claude-unraid", 0755);
    return $root;
}

function page_status_full(): array
{
    return [
        'plugin_version' => '2026.10.31.4',
        'claude' => ['version' => '2.1.309', 'source' => 'download', 'verified' => true, 'error' => ''],
        'tmux' => ['available' => true, 'version' => '3.2a', 'error' => ''],
        'mode' => 'pool',
        'config_dir' => '/mnt/cache/appdata/claude-code-unraid/config',
        'data_dir' => ['path' => '/mnt/cache/appdata/claude-code-unraid', 'valid' => true, 'fuse' => false, 'reason' => '', 'bytes' => 12345678, 'transcripts_bytes' => 1234],
        'auth' => ['login' => true, 'emergency_token' => false],
        'flash_exported' => false,
        'claude_md' => true,
        'policy_files' => ['99-claude-code-unraid-baseline.json'],
        'sessions' => ['server|running|abc123def456789|2026-10-31T10:00:00Z'],
        'workspaces' => ['server|/mnt/cache/appdata/claude-code-unraid/work/server|1700000000|running', 'media|/mnt/cache/appdata/claude-code-unraid/work/media|1700000100|-'],
    ];
}

/** @return array{0:int,1:string} */
function render_page(?array $status, string $theme = 'black', ?string $policy = null): array
{
    $root = page_root();
    @unlink("$root/status.json");
    if ($status !== null) {
        file_put_contents("$root/status.json", json_encode($status, JSON_THROW_ON_ERROR));
    }
    $drop = "$root/boot/config/plugins/claude-code-unraid/policy.d/webgui.json";
    @unlink($drop);
    if ($policy !== null) {
        file_put_contents($drop, $policy);
    }
    $helper = dirname(__DIR__) . '/helpers/render-page.php';
    [$rc, $out, $err] = run_cmd(['php', $helper, $theme], '', ['ROOT' => $root]);
    return [$rc, $out . ($err === '' ? '' : "\n[stderr] $err")];
}

function test_page_renders_cards_badges_tables_and_the_stylesheet(): void
{
    [$rc, $html] = render_page(page_status_full(), 'white-bannered');
    assert_same(0, $rc, $html);
    assert_contains('href="/plugins/claude-code-unraid/styles/claude-code-unraid.css?v=', $html);
    assert_contains('class="ccu ccu-hero" data-theme="white"', $html);
    assert_contains('src="/plugins/claude-code-unraid/images/claude-code-unraid.png"', $html);
    // cards
    assert_contains('<div class="ccu-card-value">2.1.309</div>', $html);
    assert_contains('<span class="ccu-badge" data-tone="ok">verified</span>', $html);
    assert_contains('<div class="ccu-card-value">pool</div>', $html);
    assert_contains('<div class="ccu-card-value">1</div>', $html);
    assert_contains('<div class="ccu-card-value">11.8 MiB</div>', $html);
    assert_contains('transcripts 1.2 KiB', $html);
    assert_contains('<div class="ccu-card-value">2026.10.31.4</div>', $html);
    assert_contains('1 policy file<', $html);
    assert_contains('<span class="ccu-badge" data-tone="info">CLAUDE.md</span>', $html);
    // details, sessions, workspaces
    assert_contains('<span class="ccu-path">/mnt/cache/appdata/claude-code-unraid/config</span>', $html);
    assert_contains('<span class="ccu-badge" data-tone="ok">running</span>', $html);
    assert_contains('claude-unraid attach server</code>', $html);
    assert_contains('<span class="ccu-path">abc123def456</span>', $html);
    assert_contains('onclick="openTerminal(\'ttyd\', &quot;media&quot;, &quot;/mnt/cache/appdata/claude-code-unraid/work/media&quot;)"', $html);
    assert_contains('2023-11-14', $html);
    assert_not_contains('ccu-empty', $html);
    assert_not_contains('ccu-notice', $html);
    // the settings form is untouched
    assert_contains('name="#command" value="/plugins/claude-code-unraid/scripts/install-policy"', $html);
    assert_contains(':ccu_data_dir_plug:', $html);
    assert_contains('<select name="MANAGED_CLAUDE_MD">', $html);
}

function test_page_shows_notices_warn_tones_and_empty_states(): void
{
    $s = page_status_full();
    $s['claude'] = ['version' => '', 'source' => '', 'verified' => false, 'error' => 'download failed'];
    $s['tmux'] = ['available' => false, 'version' => '', 'error' => 'not fetched'];
    $s['mode'] = 'fallback';
    $s['data_dir'] = ['path' => '/mnt/user/appdata/claude-code-unraid', 'valid' => true, 'fuse' => true, 'reason' => '', 'bytes' => null, 'transcripts_bytes' => null];
    $s['auth'] = ['login' => false, 'emergency_token' => true];
    $s['flash_exported'] = true;
    $s['claude_md'] = false;
    $s['policy_files'] = [];
    $s['sessions'] = [];
    $s['workspaces'] = [];
    [$rc, $html] = render_page($s, 'azure');
    assert_same(0, $rc, $html);
    assert_contains('data-theme="azure"', $html);
    assert_same(3, substr_count($html, '<div class="ccu-notice" data-tone="warn">'), 'flash, fuse and token notices');
    assert_contains('and so is the emergency token', $html);
    assert_contains('<div class="ccu-card" data-tone="bad">', $html);
    assert_contains('<div class="ccu-card-value">not available</div>', $html);
    assert_contains('<div class="ccu-card" data-tone="warn">', $html);
    assert_contains('<div class="ccu-card-value">fallback</div>', $html);
    assert_contains('<span class="ccu-badge" data-tone="warn">tmux missing</span>', $html);
    assert_contains('<span class="ccu-badge" data-tone="warn">/mnt/user, FUSE</span>', $html);
    assert_contains('<span class="ccu-badge" data-tone="ok">yes</span><span>managed with', $html);
    assert_contains('<div class="ccu-card-value">unknown</div>', $html);
    assert_contains('0 policy files', $html);
    assert_same(2, substr_count($html, '<div class="ccu-empty">'), 'sessions and workspaces empty states');
    assert_contains('claude-unraid start &lt;workspace&gt;</code>', $html);
    assert_contains('claude-unraid work &lt;name&gt;</code>', $html);
    assert_not_contains('<table class="ccu-table">', $html);
}

function test_page_escapes_everything_the_helper_returns(): void
{
    $s = page_status_full();
    $s['workspaces'] = ['x|/mnt/cache/appdata/x/work/<script>alert("1")</script>|1700000000|<b>'];
    $s['sessions'] = ['<i>ws</i>|running|"id"|<u>t</u>'];
    $s['data_dir']['path'] = '/mnt/"quoted"/<path>';
    $s['claude']['error'] = '<img src=x onerror=alert(1)>';
    $s['claude']['verified'] = false;
    [$rc, $html] = render_page($s, 'gray');
    assert_same(0, $rc, $html);
    foreach (['<script>alert', '<b>|', '<i>ws</i>', '<u>t</u>', '<img src=x', '/<path>'] as $raw) {
        assert_not_contains($raw, $html, "raw $raw");
    }
    assert_contains('&lt;script&gt;alert(&quot;1&quot;)&lt;/script&gt;', $html);
    assert_contains('&quot;/mnt/cache/appdata/x/work/&lt;script&gt;alert(\&quot;1\&quot;)&lt;/script&gt;&quot;', $html, 'json in onclick is html-escaped');
    assert_contains('title="&lt;img src=x onerror=alert(1)&gt;">degraded</span>', $html);
    assert_contains('<span class="ccu-badge" data-tone="warn">unverified</span>', $html);
}

function test_page_survives_a_silent_helper(): void
{
    [$rc, $html] = render_page(null, 'black');
    assert_same(0, $rc, $html);
    assert_contains('<div class="ccu-notice" data-tone="bad">', $html);
    assert_contains('did not answer', $html);
    assert_contains('<div class="ccu-card-value">not available</div>', $html);
    assert_contains('<div class="ccu-card-value">unknown</div>', $html);
    assert_contains('<div class="ccu-card-value">0</div>', $html);
    assert_contains('helper did not answer', $html);
    assert_contains('data-theme="black"', $html);
}

function test_permissions_editor_reports_the_file_state(): void
{
    [, $html] = render_page(page_status_full(), 'black');
    assert_contains('<span>no file yet</span>', $html);
    assert_contains('<textarea id="ccu_policy"', $html);
    [, $html] = render_page(page_status_full(), 'black', '{"permissions":{"allow":["Bash(git *)","Bash(ls)"],"deny":["Read(./.env)"]}}');
    assert_contains('<span>3 rules</span>', $html);
    assert_contains('&quot;Bash(git *)&quot;', $html);
    [, $html] = render_page(page_status_full(), 'black', '{"permissions":{"allow":["Bash(git *)"]}}');
    assert_contains('<span>1 rule</span>', $html);
    [, $html] = render_page(page_status_full(), 'black', '{ not json');
    assert_contains('<span>not valid JSON</span>', $html);
    assert_contains('>{ not json</textarea>', $html);
}
