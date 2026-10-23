<?php
/*
 * actions.php: the actions the Claude Code page may trigger (SPEC section 12).
 *
 *   ccu_run_action(string $action): array
 *
 * The action name is matched against a fixed allowlist; every command uses a
 * fixed binary and fixed arguments through escapeshellarg(). No request data
 * other than the action name is ever used, and the action name never reaches
 * a shell. Results are arrays ready for json_encode():
 *   ['ok' => bool, 'action' => string, ...] or ['ok' => false, 'error' => string]
 */
declare(strict_types=1);

require_once __DIR__ . '/status.php';

const CCU_ACTIONS = ['status', 'verify', 'restore', 'stop-all', 'log'];
const CCU_LOG_LINES = 200;

function ccu_run_action(string $action): array
{
    if (!in_array($action, CCU_ACTIONS, true)) {
        return ['ok' => false, 'error' => 'unknown action'];
    }
    $root = (string) getenv('ROOT');
    switch ($action) {
        case 'status':
            $status = ccu_status();
            return ['ok' => $status !== [], 'action' => 'status', 'status' => $status];
        case 'verify':
            [$rc, $out] = ccu_run_helper(['verify'], 60);
            return ['ok' => $rc === 0, 'action' => 'verify', 'rc' => $rc, 'output' => $out];
        case 'stop-all':
            [$rc, $out] = ccu_run_helper(['stop', '--all', '--timeout', '10'], 20);
            return ['ok' => $rc === 0, 'action' => 'stop-all', 'rc' => $rc, 'output' => $out];
        case 'restore':
            // Restore can take a while per session; run it detached and let the
            // page re-read the status.
            $log = $root . '/var/log/' . CCU_PLUGIN . '/restore.log';
            @mkdir(dirname($log), 0755, true);
            $cmd = 'setsid nohup ' . escapeshellarg(ccu_helper_bin()) . ' restore >> ' . escapeshellarg($log) . ' 2>&1 < /dev/null &';
            exec($cmd);
            return ['ok' => true, 'action' => 'restore', 'output' => ['restore started in the background; see /var/log/' . CCU_PLUGIN . '/restore.log']];
        case 'log':
            $file = $root . '/var/log/' . CCU_PLUGIN . '/install.log';
            $lines = [];
            if (is_readable($file)) {
                $all = file($file, FILE_IGNORE_NEW_LINES) ?: [];
                $lines = array_values(array_slice($all, -CCU_LOG_LINES));
            }
            return ['ok' => true, 'action' => 'log', 'lines' => array_map(static fn (string $l): string => preg_replace('/[\x00-\x08\x0b-\x1f\x7f]/', '', $l) ?? $l, $lines)];
    }
    return ['ok' => false, 'error' => 'unknown action'];
}
