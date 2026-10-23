<?php
/* scripts/lint-escaping: finds unescaped output, honours the allow file. */
declare(strict_types=1);

function lint_escaping_bin(): string
{
    return dirname(__DIR__, 2) . '/scripts/lint-escaping';
}

function test_unescaped_output_is_found(): void
{
    $dir = temp_dir();
    file_put_contents("$dir/bad.page", "Menu=\"Utilities\"\n---\n<p><?=\$name?></p>\n<?php echo \$x . 'y'; ?>\n");
    file_put_contents("$dir/good.php", "<?php echo ccu_h(\$x); ?><?=htmlspecialchars(\$y)?><?=json_encode(\$z)?><?='literal'?><?php echo (int) \$n; ?>\n");
    [$rc, , $err] = run_cmd(['php', lint_escaping_bin(), $dir]);
    assert_same(1, $rc);
    assert_contains('bad.page:3: unescaped output: $name', $err);
    assert_contains('bad.page:4: unescaped output: $x', $err);
    assert_not_contains('good.php', $err);
    assert_contains('2 finding(s)', $err);
}

function test_allow_file_whitelists_justified_cases(): void
{
    $dir = temp_dir();
    mkdir("$dir/tools");
    file_put_contents("$dir/tools/cli.php", "<?php echo \$usage;\n");
    file_put_contents("$dir/allow", "# comment\ntools/cli.php:^\\\$usage\n");
    [$rc, $out] = run_cmd(['php', lint_escaping_bin(), '--allow', "$dir/allow", $dir]);
    assert_same(0, $rc, 'allowed');
    assert_contains('ok', $out);
    file_put_contents("$dir/allow", "tools/cli.php:^\\\$other\n");
    [$rc] = run_cmd(['php', lint_escaping_bin(), '--allow', "$dir/allow", $dir]);
    assert_same(1, $rc, 'regex must match the expression');
}

function test_the_plugin_sources_pass(): void
{
    $repo = dirname(__DIR__, 2);
    [$rc, , $err] = run_cmd(['php', lint_escaping_bin(), '--allow', "$repo/scripts/lint-escaping.allow", "$repo/src"], '', [], );
    assert_same(0, $rc, $err);
}
