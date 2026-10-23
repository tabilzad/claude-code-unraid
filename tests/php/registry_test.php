<?php
/* scripts/registry-lib.php: selection logic for the restore step, workspace
 * derivation, pruning and normalisation of damaged entries. */
declare(strict_types=1);

require_once plugin_src('scripts/registry-lib.php');

function entry(string $id, string $ws, array $over = []): array
{
    return $over + [
        'session_id' => $id,
        'cwd' => "/data/work/$ws",
        'workspace' => $ws,
        'started_at' => '2026-01-01T10:00:00Z',
        'updated_at' => '2026-01-01T10:00:00Z',
        'ended_at' => null,
        'end_reason' => null,
        'supervised' => true,
        'remote_control' => false,
        'source' => 'startup',
        'restore' => false,
    ];
}

function test_candidates_live_supervised_newest_per_workspace(): void
{
    $reg = ['version' => 1, 'sessions' => [
        entry('a-old', 'a', ['updated_at' => '2026-01-01T09:00:00Z']),
        entry('a-new', 'a', ['updated_at' => '2026-01-01T11:00:00Z']),
        entry('b-unsupervised', 'b', ['supervised' => false]),
        entry('c-ended', 'c', ['ended_at' => '2026-01-01T12:00:00Z']),
        entry('d-flagged-ended', 'd', ['ended_at' => '2026-01-01T12:00:00Z', 'restore' => true, 'updated_at' => '2026-01-01T12:00:00Z']),
        entry('e-no-cwd', 'e', ['cwd' => '/data/work/missing']),
        entry('f-no-workspace', 'f', ['workspace' => null]),
    ]];
    $exists = static fn (string $cwd): bool => !str_contains($cwd, 'missing');
    $ids = array_map(static fn (array $s): string => $s['session_id'], registry_restore_candidates($reg, 4, $exists));
    assert_same(['d-flagged-ended', 'a-new'], $ids);
    $ids = array_map(static fn (array $s): string => $s['session_id'], registry_restore_candidates($reg, 1, $exists));
    assert_same(['d-flagged-ended'], $ids);
    assert_same([], registry_restore_candidates($reg, 0, $exists));
}

function test_workspace_from_cwd(): void
{
    assert_same('server', registry_workspace_from_cwd('/data/work/server', '/data/work'));
    assert_same('server', registry_workspace_from_cwd('/data/work/server/sub/dir', '/data/work/'));
    assert_same(null, registry_workspace_from_cwd('/data/work', '/data/work'));
    assert_same(null, registry_workspace_from_cwd('/data/workspaces/x', '/data/work'));
    assert_same(null, registry_workspace_from_cwd('/data/work/Bad Name', '/data/work'));
    assert_same(null, registry_workspace_from_cwd('/root', ''));
}

function test_record_start_and_end(): void
{
    $reg = registry_fresh();
    $reg = registry_record_start($reg, 's1', '/data/work/a', 'a', 'startup', true, false, '2026-01-01T10:00:00Z');
    $reg = registry_record_start($reg, 's1', '/data/work/a', 'a', 'compact', false, true, '2026-01-01T10:05:00Z');
    assert_same(1, count($reg['sessions']));
    assert_same(true, $reg['sessions'][0]['supervised'], 'supervised sticks');
    assert_same(true, $reg['sessions'][0]['remote_control'], 'remote sticks');
    assert_same('2026-01-01T10:00:00Z', $reg['sessions'][0]['started_at']);
    $reg = registry_record_end($reg, 's1', 'logout', '/data/work/a', '2026-01-01T11:00:00Z');
    assert_same('logout', $reg['sessions'][0]['end_reason']);
    $reg = registry_record_start($reg, 's1', '/data/work/a', 'a', 'resume', false, false, '2026-01-01T12:00:00Z');
    assert_same(null, $reg['sessions'][0]['ended_at']);
}

function test_prune_keeps_live_and_flagged_and_caps_size(): void
{
    $sessions = [];
    for ($i = 0; $i < 600; $i++) {
        $sessions[] = entry("e$i", 'w', ['ended_at' => '2026-01-01T12:00:00Z', 'updated_at' => sprintf('2026-01-01T12:%02d:%02dZ', intdiv($i, 60), $i % 60)]);
    }
    $sessions[] = entry('live', 'w');
    $sessions[] = entry('flagged', 'w', ['ended_at' => '2020-01-01T00:00:00Z', 'restore' => true]);
    $sessions[] = entry('ancient', 'w', ['ended_at' => '2020-01-01T00:00:00Z']);
    $reg = ['version' => 1, 'sessions' => $sessions];
    $reg = registry_prune($reg, 90, '2026-01-02T00:00:00Z');
    $ids = array_map(static fn (array $s): string => $s['session_id'], $reg['sessions']);
    assert_true(in_array('live', $ids, true), 'live kept');
    assert_true(in_array('flagged', $ids, true), 'flagged kept');
    assert_true(!in_array('ancient', $ids, true), 'ancient pruned');
    assert_same(REGISTRY_MAX_ENTRIES, count($ids));
}

function test_load_backs_up_damaged_files_and_normalises_entries(): void
{
    $dir = temp_dir();
    file_put_contents("$dir/sessions.json", '{"version":1,"sessions":[{"session_id":"ok","workspace":"Bad Name","supervised":"yes"},{"nope":1},"junk"]}');
    $reg = registry_load("$dir/sessions.json");
    assert_same(1, count($reg['sessions']));
    assert_same(null, $reg['sessions'][0]['workspace']);
    assert_same(true, $reg['sessions'][0]['supervised']);
    file_put_contents("$dir/sessions.json", 'garbage');
    assert_same([], registry_load("$dir/sessions.json")['sessions']);
    assert_same(1, count(glob("$dir/sessions.json.corrupt-*")));
    assert_same([], registry_load("$dir/does-not-exist.json")['sessions']);
}

function test_set_restore_and_mark_ended(): void
{
    $reg = ['version' => 1, 'sessions' => [entry('a', 'a'), entry('b', 'b')]];
    $reg = registry_set_restore($reg, ['a'], true, '2026-01-01T13:00:00Z');
    assert_same(true, $reg['sessions'][0]['restore']);
    assert_same(false, $reg['sessions'][1]['restore']);
    $reg = registry_mark_ended($reg, ['b', 'zzz'], 'stopped', '2026-01-01T13:00:00Z');
    assert_same('stopped', $reg['sessions'][1]['end_reason']);
    assert_same(null, $reg['sessions'][0]['ended_at']);
    assert_same('a', registry_live_for_workspace($reg, 'a')['session_id']);
    assert_same(null, registry_live_for_workspace($reg, 'b'));
}

function test_cleanup_days_from_cfg(): void
{
    $dir = temp_dir();
    assert_same(90, registry_cleanup_days("$dir/missing.cfg"));
    file_put_contents("$dir/x.cfg", "DATA_DIR=\"\"\nCLEANUP_DAYS=\"7\"\n");
    assert_same(7, registry_cleanup_days("$dir/x.cfg"));
    file_put_contents("$dir/x.cfg", "CLEANUP_DAYS=\"0\"\n");
    assert_same(1, registry_cleanup_days("$dir/x.cfg"));
    file_put_contents("$dir/x.cfg", "CLEANUP_DAYS=\"abc\"\n");
    assert_same(90, registry_cleanup_days("$dir/x.cfg"));
}
