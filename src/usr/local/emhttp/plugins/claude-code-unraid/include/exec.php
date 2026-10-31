<?php
/*
 * exec.php: POST endpoint for the page's buttons.
 *
 * CSRF is enforced for every POST by Unraid's local_prepend.php (the
 * csrf_token field or the X-CSRF-Token header), before this file runs.
 * The inputs used are the action name, checked against the allowlist in
 * actions.php, and for 'policy-save' the policy text, which include/policy.php
 * validates as JSON before anything is written. Responses are JSON.
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
$ccu_params = [];
if (is_string($_POST['policy'] ?? null)) {
    $ccu_params['policy'] = $_POST['policy'];
}
$ccu_result = ccu_run_action(is_string($ccu_action) ? $ccu_action : '', $ccu_params);
http_response_code($ccu_result['ok'] ? 200 : 400);
echo json_encode($ccu_result, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE), "\n";
