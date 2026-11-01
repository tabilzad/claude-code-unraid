#!/usr/bin/env php
<?php
/* Test helper: render ClaudeCode.page the way Unraid's DefaultPageLayout does,
 * minus the Markdown pass and the _()_ translation markers, which stay literal.
 *   render-page.php [THEME]
 * The page body after the "---" header is evaluated with $display['theme'] set
 * to THEME and DOCUMENT_ROOT pointing at the checkout; the helper it calls is
 * whatever ROOT/usr/local/bin/claude-unraid is. Prints the HTML. */
declare(strict_types=1);

$display = ['theme' => $argv[1] ?? 'black'];
$_SERVER['DOCUMENT_ROOT'] = dirname(__DIR__, 2) . '/src/usr/local/emhttp';
$page = file_get_contents($_SERVER['DOCUMENT_ROOT'] . '/plugins/claude-code-unraid/ClaudeCode.page');
if ($page === false) {
    fwrite(STDERR, "render-page: cannot read ClaudeCode.page\n");
    exit(2);
}
$body = preg_replace('/\A.*?^---\r?\n/ms', '', $page, 1);
// eval() of the checked-in page source is the point of this helper: it is
// what DefaultPageLayout does on the box. No request or user data is involved.
eval('?>' . $body);
