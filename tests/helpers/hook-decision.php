#!/usr/bin/env php
<?php
/* Test helper: summarise a PreToolUse hook's stdout. Prints "allow" for no
 * output, "ask: <reason>" for an ask decision, or "other: <raw>". */
declare(strict_types=1);

$raw = trim((string) stream_get_contents(STDIN));
if ($raw === '') {
    echo "allow\n";
    exit(0);
}
try {
    $d = json_decode($raw, true, 16, JSON_THROW_ON_ERROR);
} catch (JsonException) {
    echo "other: $raw\n";
    exit(0);
}
$h = $d['hookSpecificOutput'] ?? [];
if (($h['hookEventName'] ?? '') === 'PreToolUse' && ($h['permissionDecision'] ?? '') === 'ask') {
    echo 'ask: ', (string) ($h['permissionDecisionReason'] ?? ''), "\n";
    exit(0);
}
echo "other: $raw\n";
