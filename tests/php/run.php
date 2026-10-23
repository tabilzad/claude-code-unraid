#!/usr/bin/env php
<?php
/*
 * Minimal PHP test runner: no Composer, no framework.
 *
 * Every tests/php/*_test.php file is included; each function named test_*
 * is called. Assertions throw, so a failing test prints its message and the
 * runner exits 1 at the end.
 */
declare(strict_types=1);

final class AssertionFailed extends Exception
{
}

function assert_true(bool $cond, string $msg = 'expected true'): void
{
    if (!$cond) {
        throw new AssertionFailed($msg);
    }
}

function assert_same(mixed $expected, mixed $actual, string $msg = ''): void
{
    if ($expected !== $actual) {
        throw new AssertionFailed(sprintf(
            '%sexpected %s, got %s',
            $msg === '' ? '' : "$msg: ",
            var_export($expected, true),
            var_export($actual, true)
        ));
    }
}

function assert_contains(string $needle, string $haystack, string $msg = ''): void
{
    if (!str_contains($haystack, $needle)) {
        throw new AssertionFailed(sprintf(
            '%sexpected to find %s in %s',
            $msg === '' ? '' : "$msg: ",
            var_export($needle, true),
            var_export($haystack, true)
        ));
    }
}

function assert_not_contains(string $needle, string $haystack, string $msg = ''): void
{
    if (str_contains($haystack, $needle)) {
        throw new AssertionFailed(sprintf(
            '%sdid not expect to find %s in %s',
            $msg === '' ? '' : "$msg: ",
            var_export($needle, true),
            var_export($haystack, true)
        ));
    }
}

function assert_throws(callable $fn, string $msg = 'expected an exception'): void
{
    try {
        $fn();
    } catch (Throwable) {
        return;
    }
    throw new AssertionFailed($msg);
}

/** Path to a plugin source file, for tests that run the real scripts. */
function plugin_src(string $relative = ''): string
{
    $base = dirname(__DIR__, 2) . '/src/usr/local/emhttp/plugins/claude-code-unraid';
    return $relative === '' ? $base : "$base/$relative";
}

/** A fresh temporary directory, removed at exit. */
function temp_dir(): string
{
    $dir = sys_get_temp_dir() . '/ccu-php-test-' . bin2hex(random_bytes(6));
    mkdir($dir, 0700, true);
    register_shutdown_function(static function () use ($dir): void {
        exec('rm -rf ' . escapeshellarg($dir));
    });
    return $dir;
}

/**
 * Run a command with the given stdin and environment; returns
 * [exit code, stdout, stderr].
 *
 * @param list<string> $argv
 * @param array<string,string> $env
 * @return array{0:int,1:string,2:string}
 */
function run_cmd(array $argv, string $stdin = '', array $env = []): array
{
    $spec = [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
    $proc = proc_open($argv, $spec, $pipes, null, $env + getenv());
    if (!is_resource($proc)) {
        throw new RuntimeException('proc_open failed for ' . implode(' ', $argv));
    }
    fwrite($pipes[0], $stdin);
    fclose($pipes[0]);
    $out = stream_get_contents($pipes[1]) ?: '';
    $err = stream_get_contents($pipes[2]) ?: '';
    fclose($pipes[1]);
    fclose($pipes[2]);
    return [proc_close($proc), $out, $err];
}

$files = glob(__DIR__ . '/*_test.php') ?: [];
sort($files);
$passed = 0;
$failed = 0;
foreach ($files as $file) {
    $before = get_defined_functions()['user'];
    require $file;
    $after = get_defined_functions()['user'];
    $tests = array_values(array_filter(
        array_diff($after, $before),
        static fn (string $f): bool => str_starts_with($f, 'test_')
    ));
    sort($tests);
    foreach ($tests as $test) {
        try {
            $test();
            $passed++;
            printf("ok   %s::%s\n", basename($file), $test);
        } catch (Throwable $e) {
            $failed++;
            printf("FAIL %s::%s\n     %s\n", basename($file), $test, $e->getMessage());
        }
    }
}
printf("php tests: %d passed, %d failed\n", $passed, $failed);
exit($failed === 0 ? 0 : 1);
