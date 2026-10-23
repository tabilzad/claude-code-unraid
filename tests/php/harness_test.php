<?php
/* Proves the PHP runner: assertions, temp dirs and JSON handling with the
 * flags the plugin uses everywhere. */
declare(strict_types=1);

function test_json_round_trip(): void
{
    $data = ['permissions' => ['defaultMode' => 'default'], 'list' => [1, 2]];
    $json = json_encode($data, JSON_THROW_ON_ERROR | JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    assert_same($data, json_decode($json, true, 512, JSON_THROW_ON_ERROR));
}

function test_invalid_json_throws(): void
{
    assert_throws(static function (): void {
        json_decode('{not json', true, 512, JSON_THROW_ON_ERROR);
    });
}

function test_temp_dir_is_private(): void
{
    $dir = temp_dir();
    assert_true(is_dir($dir));
    assert_same('700', substr(sprintf('%o', fileperms($dir)), -3));
}

function test_run_cmd_captures_streams_and_exit_code(): void
{
    [$rc, $out, $err] = run_cmd(['sh', '-c', 'cat; echo err >&2; exit 3'], "in\n");
    assert_same(3, $rc);
    assert_same("in\n", $out);
    assert_same("err\n", $err);
}
