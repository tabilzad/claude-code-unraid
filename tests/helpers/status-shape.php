<?php
/* Test helper: does a `claude-unraid status --json` document have the documented
 * shape and the values the fixture sets up? Prints "shape ok" or the document. */
declare(strict_types=1);

$s = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$ok = ($s['plugin_version'] ?? null) === '2026.01.02.3'
    && ($s['claude']['version'] ?? null) === '1.2.3'
    && ($s['claude']['verified'] ?? null) === true
    && ($s['claude']['error'] ?? null) === ''
    && ($s['tmux']['available'] ?? null) === true
    && ($s['tmux']['version'] ?? null) === '3.2a'
    && ($s['mode'] ?? null) === 'fallback'
    && ($s['data_dir']['valid'] ?? null) === true
    && ($s['data_dir']['fuse'] ?? null) === true
    && ($s['auth']['login'] ?? null) === false
    && ($s['auth']['emergency_token'] ?? null) === false
    && ($s['flash_exported'] ?? null) === false
    && ($s['policy_files'] ?? null) === ['99-claude-code-unraid-baseline.json'];
echo $ok ? "shape ok\n" : 'shape BAD: ' . json_encode($s) . "\n";
