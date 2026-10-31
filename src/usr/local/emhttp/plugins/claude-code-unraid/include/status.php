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

/** 12345678 -> "11.8 MiB"; anything but a non-negative int -> "unknown" */
function ccu_bytes(mixed $bytes): string
{
    if (!is_int($bytes) || $bytes < 0) {
        return 'unknown';
    }
    $units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    $v = (float) $bytes;
    $u = 0;
    while ($v >= 1024 && $u < count($units) - 1) {
        $v /= 1024;
        $u++;
    }
    return $u === 0 ? sprintf('%d B', $bytes) : sprintf('%.1f %s', $v, $units[$u]);
}

/** Only this much of a log file is read for a tail, counted from its end. */
const CCU_TAIL_WINDOW = 4194304;

/**
 * The last $max lines of $file that contain $needle, control characters
 * removed. A file larger than CCU_TAIL_WINDOW is read from its tail only, and
 * the partial line at the cut is dropped.
 *
 * @return list<string>
 */
function ccu_tail_matching(string $file, string $needle, int $max): array
{
    if (!is_readable($file)) {
        return [];
    }
    $fh = @fopen($file, 'rb');
    if ($fh === false) {
        return [];
    }
    $size = (int) @filesize($file);
    $cut = false;
    if ($size > CCU_TAIL_WINDOW) {
        fseek($fh, $size - CCU_TAIL_WINDOW);
        $cut = true;
    }
    $data = stream_get_contents($fh);
    fclose($fh);
    if ($data === false) {
        return [];
    }
    $lines = explode("\n", $data);
    if ($cut) {
        array_shift($lines);
    }
    $out = [];
    foreach ($lines as $line) {
        if ($line !== '' && str_contains($line, $needle)) {
            $out[] = preg_replace('/[\x00-\x08\x0b-\x1f\x7f]/', '', rtrim($line, "\r")) ?? '';
        }
    }
    return array_values(array_slice($out, -$max));
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
