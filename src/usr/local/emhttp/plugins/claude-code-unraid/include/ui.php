<?php
/*
 * Claude Code for Unraid: presentation helpers for the settings page.
 *
 * Copyright (c) 2026 tabilzad. MIT License (https://github.com/tabilzad/claude-code-unraid).
 * Not affiliated with Anthropic PBC or Lime Technology, Inc.
 *
 * Pure functions, no I/O except ccu_asset_version(): the theme name Unraid
 * reports, badges, inline SVG icons and the rule count shown above the
 * Permissions editor. Everything that reaches HTML goes through ccu_h().
 */
declare(strict_types=1);

require_once __DIR__ . '/status.php';

/** The four Unraid themes the stylesheet carries fallbacks for. */
const CCU_THEMES = ['black', 'white', 'azure', 'gray'];

/** Badge and card tones the stylesheet knows. */
const CCU_TONES = ['ok', 'warn', 'bad', 'info', 'neutral'];

/**
 * Normalise Unraid's display theme ("white-bannered", "azure", "grey", ...) to
 * one of CCU_THEMES. Unknown or empty values fall back to black, the default
 * theme and the one the stylesheet's base tokens are written for.
 */
function ccu_theme(mixed $raw): string
{
    $name = strtolower(trim(is_string($raw) ? $raw : ''));
    $name = strtok($name, '-') ?: '';
    if ($name === 'grey') {
        $name = 'gray';
    }
    return in_array($name, CCU_THEMES, true) ? $name : 'black';
}

/** A pill badge. Unknown tones render as neutral. */
function ccu_badge(mixed $label, string $tone = 'neutral'): string
{
    $tone = in_array($tone, CCU_TONES, true) ? $tone : 'neutral';
    return '<span class="ccu-badge" data-tone="' . $tone . '">' . ccu_h($label) . '</span>';
}

/** yes/no as a badge: yes is ok, no is neutral unless $no_is_bad. */
function ccu_yesno_badge(mixed $v, bool $no_is_bad = false): string
{
    $yes = $v === true || $v === 'yes';
    return ccu_badge($yes ? 'yes' : 'no', $yes ? 'ok' : ($no_is_bad ? 'bad' : 'neutral'));
}

/**
 * Inline SVG icons (stroke based, 24-unit viewBox, 1.8 stroke). The markup is
 * constant and carries no user data. Unknown names give an empty string.
 */
function ccu_icon(string $name): string
{
    static $paths = [
        'shield' => '<path d="M12 3.5 19 6.25v5.25c0 4.4-2.75 7.5-7 9-4.25-1.5-7-4.6-7-9V6.25Z"/><path d="m9.25 12 2 2 3.75-4"/>',
        'pulse' => '<path d="M3 12h4l2.5-6 4 12 2.5-6h5"/>',
        'log' => '<path d="M6 3h8l4 4v14H6Z"/><path d="M14 3v5h4M9 12h6M9 16h6"/>',
        'audit' => '<path d="M3 12a9 9 0 1 0 3-6.7"/><path d="M3 4.5v5h5"/><path d="M12 7.5v5l3.25 1.9"/>',
        'restore' => '<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4.5v5h-5"/><path d="m10 9 5 3-5 3Z"/>',
        'stop' => '<rect x="5" y="5" width="14" height="14" rx="2"/>',
        'terminal' => '<rect x="3" y="4.5" width="18" height="15" rx="2"/><path d="m7 9 3 3-3 3M12.5 15H17"/>',
        'save' => '<path d="M5 4h11l3 3v13H5Z"/><path d="M8 4v5h7V4M8 20v-6h8v6"/>',
        'example' => '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M5.6 5.6l2.8 2.8M15.6 15.6l2.8 2.8M5.6 18.4l2.8-2.8M15.6 8.4l2.8-2.8"/>',
        'warning' => '<path d="M12 4 2.5 20h19Z"/><path d="M12 10v4M12 17h.01"/>',
        'info' => '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
        'folder' => '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h4l2 2.5h9A1.5 1.5 0 0 1 21 9v9.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5Z"/>',
        'sessions' => '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>',
    ];
    if (!isset($paths[$name])) {
        return '';
    }
    return '<svg class="ccu-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' . $paths[$name] . '</svg>';
}

/**
 * How many allow, ask and deny rules a policy drop-in holds, or null when the
 * text is empty or not a JSON object. Used for the line above the editor
 * only; include/policy.php does the real validation on save.
 */
function ccu_policy_rule_count(string $raw): ?int
{
    $raw = trim($raw);
    if ($raw === '') {
        return null;
    }
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        return null;
    }
    $perm = $data['permissions'] ?? null;
    if (!is_array($perm)) {
        return 0;
    }
    $n = 0;
    foreach (['allow', 'ask', 'deny'] as $k) {
        if (is_array($perm[$k] ?? null)) {
            $n += count($perm[$k]);
        }
    }
    return $n;
}

/** Cache-busting token for a packaged asset: its mtime, or "dev" when missing. */
function ccu_asset_version(string $path): string
{
    $t = @filemtime($path);
    return $t === false ? 'dev' : (string) $t;
}
