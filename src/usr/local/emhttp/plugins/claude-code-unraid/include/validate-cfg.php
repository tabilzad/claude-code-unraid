<?php
/*
 * validate-cfg.php: server-side validation of the settings form.
 *
 *   ccu_validate_cfg(array $post, callable $dataDirCheck): array
 *     returns ['save' => bool, 'post' => array, 'messages' => list<string>]
 *
 * $dataDirCheck(string $path): array{valid:bool, reason:string} runs
 * `scripts/data-dir --check PATH` in production and is replaced in tests.
 * Only the plugin's own keys survive; values are normalised; anything that is
 * not a valid value stops the save with a message for the user.
 */
declare(strict_types=1);

const CCU_CFG_KEYS = ['DATA_DIR', 'CHANNEL', 'RESTORE_SESSIONS', 'MAX_RESTORE', 'CLEANUP_DAYS', 'ALLOW_AUTO_MODE', 'ALLOW_BOOT_RW', 'REMOTE_CONTROL', 'EVENT_TIMEOUT', 'MANAGED_CLAUDE_MD'];

function ccu_validate_cfg(array $post, callable $dataDirCheck): array
{
    $messages = [];
    $save = true;
    $clean = [];

    foreach ($post as $key => $value) {
        if (!is_string($key) || $key === '' || $key[0] === '#') {
            continue; // update.php's own control fields
        }
        if (!in_array($key, CCU_CFG_KEYS, true)) {
            $messages[] = "ignored unknown setting '" . $key . "'";
            continue;
        }
        if (!is_string($value)) {
            $save = false;
            $messages[] = "$key: unexpected value";
            continue;
        }
        $clean[$key] = trim(preg_replace('/[\x00-\x1f\x7f]/', '', $value) ?? '');
    }

    foreach (['RESTORE_SESSIONS', 'ALLOW_AUTO_MODE', 'ALLOW_BOOT_RW', 'REMOTE_CONTROL', 'MANAGED_CLAUDE_MD'] as $k) {
        if (array_key_exists($k, $clean)) {
            $v = strtolower($clean[$k]);
            if (!in_array($v, ['yes', 'no'], true)) {
                $save = false;
                $messages[] = "$k must be yes or no";
            }
            $clean[$k] = $v;
        }
    }
    $ranges = ['MAX_RESTORE' => [0, 20], 'CLEANUP_DAYS' => [1, 3650], 'EVENT_TIMEOUT' => [5, 120]];
    foreach ($ranges as $k => [$min, $max]) {
        if (array_key_exists($k, $clean)) {
            if (!preg_match('/^[0-9]{1,5}$/', $clean[$k]) || (int) $clean[$k] < $min || (int) $clean[$k] > $max) {
                $save = false;
                $messages[] = "$k must be a whole number between $min and $max";
            } else {
                $clean[$k] = (string) (int) $clean[$k];
            }
        }
    }
    if (array_key_exists('CHANNEL', $clean) && $clean['CHANNEL'] !== 'stable') {
        $clean['CHANNEL'] = 'stable';
    }
    if (array_key_exists('DATA_DIR', $clean)) {
        $path = rtrim($clean['DATA_DIR'], '/');
        if ($path !== '') {
            if (!preg_match('#^/mnt/[^\s"\'`$\\\\]+$#', $path) || str_contains($path, '/../') || str_ends_with($path, '/..')) {
                $save = false;
                $messages[] = 'DATA_DIR must be an absolute path under /mnt without spaces or quotes';
            } else {
                $check = $dataDirCheck($path);
                if (!($check['valid'] ?? false)) {
                    $reason = (string) ($check['reason'] ?? 'not usable');
                    if (str_contains($reason, 'not mounted')) {
                        $messages[] = "DATA_DIR saved; it will be checked when the array starts ($reason)";
                    } else {
                        $save = false;
                        $messages[] = "DATA_DIR not usable: $reason";
                    }
                }
            }
        }
        $clean['DATA_DIR'] = $path;
    }

    return ['save' => $save, 'post' => $clean, 'messages' => $messages];
}
