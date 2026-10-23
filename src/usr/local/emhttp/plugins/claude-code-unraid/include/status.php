<?php
/*
 * status.php: helpers shared by the Claude Code page and its endpoints.
 *
 * Everything the page shows comes from `claude-unraid status --json`; nothing
 * here parses state files itself. Every value printed into HTML goes through
 * ccu_h(). No token, e-mail or transcript content is ever read here.
 */
declare(strict_types=1);

const CCU_PLUGIN = 'claude-code-unraid';

/** The plugin's helper binary, with the ROOT prefix the test suite uses. */
function ccu_helper_bin(): string
{
    return (string) getenv('ROOT') . '/usr/local/bin/claude-unraid';
}

/** HTML-escape for output into the page. */
function ccu_h(mixed $value): string
{
    return htmlspecialchars((string) $value, ENT_QUOTES | ENT_SUBSTITUTE | ENT_HTML5, 'UTF-8');
}

/**
 * Run the helper with fixed arguments and a timeout; returns [rc, output lines].
 * Arguments are constants chosen by the caller, never request data.
 *
 * @param list<string> $args
 * @return array{0:int,1:list<string>}
 */
function ccu_run_helper(array $args, int $timeout = 20): array
{
    $cmd = 'timeout ' . (int) $timeout . ' ' . escapeshellarg(ccu_helper_bin());
    foreach ($args as $a) {
        $cmd .= ' ' . escapeshellarg($a);
    }
    $out = [];
    $rc = 1;
    exec($cmd . ' 2>&1', $out, $rc);
    return [$rc, array_map(static fn ($l): string => (string) $l, $out)];
}

/** `claude-unraid status --json` decoded, or [] when unavailable. */
function ccu_status(): array
{
    [$rc, $out] = ccu_run_helper(['status', '--json']);
    if ($rc !== 0) {
        return [];
    }
    try {
        $data = json_decode(implode("\n", $out), true, 16, JSON_THROW_ON_ERROR);
    } catch (JsonException) {
        return [];
    }
    return is_array($data) ? $data : [];
}

/** yes/no for a boolean-ish status value */
function ccu_yesno(mixed $v): string
{
    return $v === true || $v === 'yes' ? 'yes' : 'no';
}

/** The plugin cfg, user values over defaults, without sourcing anything. */
function ccu_cfg(): array
{
    $root = (string) getenv('ROOT');
    $cfg = [];
    foreach ([$root . '/usr/local/emhttp/plugins/' . CCU_PLUGIN . '/default.cfg', $root . '/boot/config/plugins/' . CCU_PLUGIN . '/' . CCU_PLUGIN . '.cfg'] as $file) {
        if (!is_readable($file)) {
            continue;
        }
        foreach (file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
            if (preg_match('/^([A-Z_][A-Z0-9_]*)=(.*)$/', trim($line), $m)) {
                $v = $m[2];
                if (str_starts_with($v, '"')) {
                    $v = substr($v, 1);
                    $v = substr($v, 0, strpos($v, '"') === false ? strlen($v) : strpos($v, '"'));
                }
                $cfg[$m[1]] = $v;
            }
        }
    }
    return $cfg;
}
