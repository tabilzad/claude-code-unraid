<?php
/*
 * registry-lib.php: the session registry (SPEC section 10).
 *
 * <DATA_DIR>/sessions.json in pool mode, /run/<plugin>/sessions.json in
 * fallback mode:
 *
 *   {"version": 1, "sessions": [
 *     {"session_id": "...", "cwd": "/mnt/.../work/server", "workspace": "server",
 *      "started_at": "2026-10-23T05:00:00Z", "updated_at": "...", "ended_at": null,
 *      "end_reason": null, "supervised": true, "remote_control": false,
 *      "source": "startup", "restore": false}
 *   ]}
 *
 * "restore" is set by `claude-unraid stop --mark-restore` (the array is
 * stopping; bring the session back after disks_mounted) and cleared once the
 * restore step has handled the entry. A supervised entry without ended_at is
 * also a restore candidate: that is what an unclean shutdown leaves behind.
 *
 * Writes happen under flock on <file>.lock and go through a temp file plus
 * rename. A registry that does not parse is moved aside
 * (sessions.json.corrupt-<timestamp>) and a fresh one is started: a session
 * must never fail because the registry is damaged.
 */
declare(strict_types=1);

const REGISTRY_VERSION = 1;
const REGISTRY_MAX_ENTRIES = 500;
const WORKSPACE_RE = '/^[a-z0-9][a-z0-9._-]{0,47}$/';

function registry_now(): string
{
    return gmdate('Y-m-d\TH:i:s\Z');
}

/** @return array{version:int,sessions:list<array<string,mixed>>} */
function registry_fresh(): array
{
    return ['version' => REGISTRY_VERSION, 'sessions' => []];
}

/** Load the registry; a damaged file is backed up and replaced by a fresh one. */
function registry_load(string $file): array
{
    if (!is_file($file)) {
        return registry_fresh();
    }
    $raw = @file_get_contents($file);
    if ($raw === false || trim($raw) === '') {
        return registry_fresh();
    }
    try {
        $data = json_decode($raw, true, 16, JSON_THROW_ON_ERROR);
    } catch (JsonException) {
        $data = null;
    }
    if (!is_array($data) || !isset($data['sessions']) || !is_array($data['sessions'])) {
        @rename($file, $file . '.corrupt-' . gmdate('Ymd\THis\Z'));
        return registry_fresh();
    }
    $sessions = [];
    foreach ($data['sessions'] as $s) {
        if (is_array($s) && isset($s['session_id']) && is_string($s['session_id']) && $s['session_id'] !== '') {
            $sessions[] = registry_normalize($s);
        }
    }
    return ['version' => REGISTRY_VERSION, 'sessions' => $sessions];
}

/** @param array<string,mixed> $s */
function registry_normalize(array $s): array
{
    return [
        'session_id' => (string) $s['session_id'],
        'cwd' => isset($s['cwd']) && is_string($s['cwd']) ? $s['cwd'] : '',
        'workspace' => isset($s['workspace']) && is_string($s['workspace']) && preg_match(WORKSPACE_RE, $s['workspace']) ? $s['workspace'] : null,
        'started_at' => isset($s['started_at']) && is_string($s['started_at']) ? $s['started_at'] : registry_now(),
        'updated_at' => isset($s['updated_at']) && is_string($s['updated_at']) ? $s['updated_at'] : registry_now(),
        'ended_at' => isset($s['ended_at']) && is_string($s['ended_at']) ? $s['ended_at'] : null,
        'end_reason' => isset($s['end_reason']) && is_string($s['end_reason']) ? $s['end_reason'] : null,
        'supervised' => (bool) ($s['supervised'] ?? false),
        'remote_control' => (bool) ($s['remote_control'] ?? false),
        'source' => isset($s['source']) && is_string($s['source']) ? $s['source'] : null,
        'restore' => (bool) ($s['restore'] ?? false),
    ];
}

/** Atomic write, mode 0600 (transcripts paths and session ids are private). */
function registry_save(string $file, array $reg): void
{
    $dir = dirname($file);
    if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
        throw new RuntimeException("cannot create $dir");
    }
    $tmp = $dir . '/.sessions.' . bin2hex(random_bytes(4)) . '.tmp';
    $json = json_encode($reg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
    if (@file_put_contents($tmp, $json) === false) {
        throw new RuntimeException("cannot write $tmp");
    }
    @chmod($tmp, 0600);
    if (!@rename($tmp, $file)) {
        @unlink($tmp);
        throw new RuntimeException("cannot replace $file");
    }
}

/**
 * Run $fn(array $reg): array under an exclusive lock and save the result.
 * @param callable(array):array $fn
 */
function registry_update(string $file, callable $fn): array
{
    $dir = dirname($file);
    if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
        throw new RuntimeException("cannot create $dir");
    }
    $lock = fopen($file . '.lock', 'c');
    if ($lock === false) {
        throw new RuntimeException("cannot open lock for $file");
    }
    try {
        if (!flock($lock, LOCK_EX)) {
            throw new RuntimeException("cannot lock $file");
        }
        $reg = $fn(registry_load($file));
        registry_save($file, $reg);
        return $reg;
    } finally {
        flock($lock, LOCK_UN);
        fclose($lock);
    }
}

/** The workspace name when $cwd is <workDir>/<name>[/...], else null. */
function registry_workspace_from_cwd(string $cwd, string $workDir): ?string
{
    $workDir = rtrim($workDir, '/');
    if ($workDir === '' || !str_starts_with($cwd, $workDir . '/')) {
        return null;
    }
    $rest = substr($cwd, strlen($workDir) + 1);
    $name = explode('/', $rest, 2)[0];
    return preg_match(WORKSPACE_RE, $name) ? $name : null;
}

function &registry_find(array &$reg, string $sessionId): ?array
{
    foreach ($reg['sessions'] as &$s) {
        if ($s['session_id'] === $sessionId) {
            return $s;
        }
    }
    $null = null;
    return $null;
}

/**
 * SessionStart. $source is startup|resume|clear|compact|fork; the entry for
 * the session id is updated or created.
 */
function registry_record_start(array $reg, string $sessionId, string $cwd, ?string $workspace, string $source, bool $supervised, bool $remote, string $now): array
{
    $entry = &registry_find($reg, $sessionId);
    if ($entry !== null) {
        $entry['cwd'] = $cwd !== '' ? $cwd : $entry['cwd'];
        $entry['workspace'] = $workspace ?? $entry['workspace'];
        $entry['updated_at'] = $now;
        $entry['source'] = $source;
        $entry['ended_at'] = null;
        $entry['end_reason'] = null;
        $entry['supervised'] = $entry['supervised'] || $supervised;
        $entry['remote_control'] = $entry['remote_control'] || $remote;
        unset($entry);
        return $reg;
    }
    unset($entry);
    $reg['sessions'][] = [
        'session_id' => $sessionId,
        'cwd' => $cwd,
        'workspace' => $workspace,
        'started_at' => $now,
        'updated_at' => $now,
        'ended_at' => null,
        'end_reason' => null,
        'supervised' => $supervised,
        'remote_control' => $remote,
        'source' => $source,
        'restore' => false,
    ];
    return $reg;
}

function registry_record_end(array $reg, string $sessionId, string $reason, string $cwd, string $now): array
{
    $entry = &registry_find($reg, $sessionId);
    if ($entry === null) {
        unset($entry);
        $reg['sessions'][] = [
            'session_id' => $sessionId,
            'cwd' => $cwd,
            'workspace' => null,
            'started_at' => $now,
            'updated_at' => $now,
            'ended_at' => $now,
            'end_reason' => $reason,
            'supervised' => false,
            'remote_control' => false,
            'source' => null,
            'restore' => false,
        ];
        return $reg;
    }
    $entry['ended_at'] = $now;
    $entry['end_reason'] = $reason;
    $entry['updated_at'] = $now;
    unset($entry);
    return $reg;
}

/** Drop ended entries older than $days (unless flagged for restore) and cap the size. */
function registry_prune(array $reg, int $days, string $now): array
{
    $cutoff = strtotime($now) - max(1, $days) * 86400;
    $kept = [];
    foreach ($reg['sessions'] as $s) {
        if ($s['ended_at'] !== null && !$s['restore']) {
            $t = strtotime($s['ended_at']);
            if ($t !== false && $t < $cutoff) {
                continue;
            }
        }
        $kept[] = $s;
    }
    if (count($kept) > REGISTRY_MAX_ENTRIES) {
        usort($kept, static function (array $a, array $b): int {
            // live or flagged entries first (kept), then newest first
            $la = ($a['ended_at'] === null || $a['restore']) ? 1 : 0;
            $lb = ($b['ended_at'] === null || $b['restore']) ? 1 : 0;
            if ($la !== $lb) {
                return $lb <=> $la;
            }
            return strcmp($b['updated_at'], $a['updated_at']);
        });
        $kept = array_slice($kept, 0, REGISTRY_MAX_ENTRIES);
    }
    $reg['sessions'] = array_values($kept);
    return $reg;
}

/**
 * Entries to bring back after disks_mounted: flagged for restore, or
 * supervised and never ended (unclean shutdown); newest first; one per
 * workspace; cwd must still exist; at most $max.
 * @param callable(string):bool $cwdExists
 * @return list<array<string,mixed>>
 */
function registry_restore_candidates(array $reg, int $max, callable $cwdExists): array
{
    $cands = array_filter($reg['sessions'], static function (array $s) use ($cwdExists): bool {
        if (!($s['restore'] || ($s['supervised'] && $s['ended_at'] === null))) {
            return false;
        }
        if ($s['workspace'] === null || $s['cwd'] === '') {
            return false;
        }
        return $cwdExists($s['cwd']);
    });
    if ($max <= 0) {
        return [];
    }
    usort($cands, static fn (array $a, array $b): int => strcmp($b['updated_at'], $a['updated_at']));
    $seen = [];
    $out = [];
    foreach ($cands as $s) {
        if (isset($seen[$s['workspace']])) {
            continue;
        }
        $seen[$s['workspace']] = true;
        $out[] = $s;
        if (count($out) >= $max) {
            break;
        }
    }
    return $out;
}

/** The newest live supervised entry for a workspace, or null. */
function registry_live_for_workspace(array $reg, string $workspace): ?array
{
    $best = null;
    foreach ($reg['sessions'] as $s) {
        if ($s['workspace'] === $workspace && $s['supervised'] && $s['ended_at'] === null) {
            if ($best === null || strcmp($s['updated_at'], $best['updated_at']) > 0) {
                $best = $s;
            }
        }
    }
    return $best;
}

/** @param list<string> $ids */
function registry_set_restore(array $reg, array $ids, bool $flag, string $now): array
{
    foreach ($reg['sessions'] as &$s) {
        if (in_array($s['session_id'], $ids, true)) {
            $s['restore'] = $flag;
            $s['updated_at'] = $now;
        }
    }
    unset($s);
    return $reg;
}

/** @param list<string> $ids */
function registry_mark_ended(array $reg, array $ids, string $reason, string $now): array
{
    foreach ($reg['sessions'] as &$s) {
        if (in_array($s['session_id'], $ids, true) && $s['ended_at'] === null) {
            $s['ended_at'] = $now;
            $s['end_reason'] = $reason;
            $s['updated_at'] = $now;
        }
    }
    unset($s);
    return $reg;
}

/** CLEANUP_DAYS from the plugin cfg (KEY="value" lines), default 90. */
function registry_cleanup_days(string $cfgFile): int
{
    $days = 90;
    if (is_readable($cfgFile)) {
        foreach (file($cfgFile, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
            if (preg_match('/^CLEANUP_DAYS="?([0-9]{1,5})"?\s*$/', trim($line), $m)) {
                $days = max(1, (int) $m[1]);
            }
        }
    }
    return $days;
}
