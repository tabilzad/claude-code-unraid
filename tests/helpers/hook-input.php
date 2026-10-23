#!/usr/bin/env php
<?php
/*
 * Test helper: print a hook input document.
 *
 *   hook-input.php bash  "COMMAND"            PreToolUse for Bash
 *   hook-input.php write "/path" [TOOL]       PreToolUse for Write (or Edit, MultiEdit, NotebookEdit)
 *   hook-input.php tool  NAME                 PreToolUse for another tool
 *   hook-input.php post  TOOL KEY=VALUE...    PostToolUse with the given tool_input fields
 */
declare(strict_types=1);

[, $mode] = $argv + [null, null];
$common = [
    'session_id' => 'sess-0123456789abcdef',
    'transcript_path' => '/data/config/projects/-data-work-server/sess.jsonl',
    'cwd' => '/data/work/server',
    'permission_mode' => 'default',
];
switch ($mode) {
    case 'bash':
        $doc = $common + ['hook_event_name' => 'PreToolUse', 'tool_name' => 'Bash', 'tool_input' => ['command' => $argv[2] ?? '']];
        break;
    case 'write':
        $tool = $argv[3] ?? 'Write';
        $key = $tool === 'NotebookEdit' ? 'notebook_path' : 'file_path';
        $doc = $common + ['hook_event_name' => 'PreToolUse', 'tool_name' => $tool, 'tool_input' => [$key => $argv[2] ?? '', 'content' => 'x']];
        break;
    case 'tool':
        $doc = $common + ['hook_event_name' => 'PreToolUse', 'tool_name' => $argv[2] ?? 'Read', 'tool_input' => ['file_path' => '/etc/claude-code/x']];
        break;
    case 'post':
        $fields = [];
        foreach (array_slice($argv, 3) as $kv) {
            [$k, $v] = array_pad(explode('=', $kv, 2), 2, '');
            $fields[$k] = $v;
        }
        $doc = $common + ['hook_event_name' => 'PostToolUse', 'tool_name' => $argv[2] ?? 'Bash', 'tool_input' => $fields, 'tool_response' => ['stdout' => 'SECRET OUTPUT MUST NOT BE LOGGED']];
        break;
    default:
        fwrite(STDERR, "unknown mode\n");
        exit(1);
}
echo json_encode($doc, JSON_UNESCAPED_SLASHES), "\n";
