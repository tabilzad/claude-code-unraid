#!/usr/bin/env php
<?php
/* Test helper: run include/exec.php as if it had been requested.
 *   run-exec.php METHOD [ACTION [POLICY_TEXT]]
 * Prints what exec.php printed (JSON). CSRF is Unraid's job (local_prepend.php),
 * so it is not part of this harness. */
declare(strict_types=1);

$_SERVER['REQUEST_METHOD'] = $argv[1] ?? 'GET';
if (isset($argv[2])) {
    $_POST['action'] = $argv[2];
}
if (isset($argv[3])) {
    $_POST['policy'] = $argv[3];
}
require dirname(__DIR__, 2) . '/src/usr/local/emhttp/plugins/claude-code-unraid/include/exec.php';
