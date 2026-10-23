<?php
/* Test helper: structural mutations of a rendered .plg that sed cannot do
 * comfortably (multi-line regions). Usage: plg-mutate.php MODE IN OUT */
declare(strict_types=1);

[, $mode, $in, $out] = $argv + [null, null, null, null];
$s = file_get_contents($in);
if ($s === false) {
    fwrite(STDERR, "cannot read $in\n");
    exit(1);
}
$s = match ($mode) {
    'empty-changes' => preg_replace('#<CHANGES>.*</CHANGES>#s', "<CHANGES>\n</CHANGES>", $s),
    'drop-remove' => preg_replace('#<FILE Run="/bin/bash" Method="remove">.*?</FILE>#s', '', $s),
    default => null,
};
if ($s === null) {
    fwrite(STDERR, "unknown mode $mode\n");
    exit(1);
}
file_put_contents($out, $s);
