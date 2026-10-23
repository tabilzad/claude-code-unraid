#!/usr/bin/env php
<?php
/* Test helper: print the JSON-encoded value at a dotted path in a JSON file,
 * or MISSING. Example: json-get.php policy.json hooks.PreToolUse.0.hooks.0.command */
declare(strict_types=1);

[, $file, $path] = $argv + [null, null, null];
$data = json_decode((string) file_get_contents((string) $file), true, 64, JSON_THROW_ON_ERROR);
foreach (explode('.', (string) $path) as $part) {
    if (!is_array($data) || !array_key_exists($part, $data)) {
        echo "MISSING\n";
        exit(0);
    }
    $data = $data[$part];
}
echo json_encode($data, JSON_UNESCAPED_SLASHES), "\n";
