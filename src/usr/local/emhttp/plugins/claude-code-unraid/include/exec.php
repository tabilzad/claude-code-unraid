<?php
/*
 * exec.php: POST endpoint for the page's buttons.
 *
 * CSRF is enforced for every POST by Unraid's local_prepend.php (the
 * csrf_token field or the X-CSRF-Token header), before this file runs.
 * The only input used is the action name, checked against the allowlist in
 * actions.php. Responses are JSON.
 */
declare(strict_types=1);

require_once __DIR__ . '/actions.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    echo json_encode(['ok' => false, 'error' => 'POST required'], JSON_UNESCAPED_SLASHES), "\n";
    exit;
}

$ccu_action = $_POST['action'] ?? '';
$ccu_result = ccu_run_action(is_string($ccu_action) ? $ccu_action : '');
http_response_code($ccu_result['ok'] ? 200 : 400);
echo json_encode($ccu_result, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE), "\n";
