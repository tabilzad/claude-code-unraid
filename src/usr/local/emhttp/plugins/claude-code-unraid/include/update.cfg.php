<?php
/*
 * update.cfg.php: the "#include" update.php runs before it writes
 * /boot/config/plugins/claude-code-unraid/claude-code-unraid.cfg.
 *
 * update.php provides $_POST, $keys, $save and write_log(). This file
 * validates and normalises the posted settings (include/validate-cfg.php),
 * replaces $_POST with the cleaned values so that only known keys are written,
 * and sets $save = false with a message when a value is not acceptable. The
 * data directory is checked with scripts/data-dir --check.
 */
declare(strict_types=1);

require_once __DIR__ . '/validate-cfg.php';

$ccu_result = ccu_validate_cfg($_POST, static function (string $path): array {
    $bin = (string) getenv('ROOT') . '/usr/local/emhttp/plugins/claude-code-unraid/scripts/data-dir';
    $out = [];
    $rc = 1;
    exec('timeout 10 ' . escapeshellarg($bin) . ' --check ' . escapeshellarg($path) . ' 2>/dev/null', $out, $rc);
    $reason = '';
    foreach ($out as $line) {
        if (str_starts_with($line, 'REASON=')) {
            $reason = substr($line, 7);
        }
    }
    return ['valid' => $rc === 0, 'reason' => $reason];
});

foreach (array_keys($_POST) as $ccu_key) {
    if (is_string($ccu_key) && $ccu_key !== '' && $ccu_key[0] !== '#') {
        unset($_POST[$ccu_key]);
    }
}
foreach ($ccu_result['post'] as $ccu_key => $ccu_value) {
    $_POST[$ccu_key] = $ccu_value;
}
foreach ($ccu_result['messages'] as $ccu_message) {
    if (function_exists('write_log')) {
        write_log('Claude Code: ' . $ccu_message);
    }
}
if (!$ccu_result['save']) {
    $save = false;
    if (function_exists('write_log')) {
        write_log('Claude Code: settings NOT saved. Fix the values above and apply again.');
    }
}
