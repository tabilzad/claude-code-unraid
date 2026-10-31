<?php
/*
 * policy.php: the user policy drop-in that the settings page edits.
 *
 *   ccu_policy_path(): string          ROOT/boot/config/plugins/PLUGIN/policy.d/webgui.json
 *   ccu_policy_read(): string          its current content, '' when absent
 *   ccu_validate_policy(string $raw): array
 *       ['ok' => bool, 'errors' => list<string>, 'notes' => list<string>, 'json' => ?string]
 *       json is the normalised text to store, null when the drop-in should
 *       not exist (empty text or an empty object).
 *   ccu_policy_save(string $raw): array
 *       validate, write or remove the drop-in, run install-policy; returns an
 *       action result for exec.php.
 *
 * The file is one of the policy.d drop-ins that install-policy copies into
 * /etc/claude-code/managed-settings.d/ as 50-user-webgui.json (SPEC section
 * 9). The plugin's baseline loads after it, so the drop-in can add permission
 * rules and settings but cannot weaken the locks. Nothing from the request
 * reaches a shell: the text is parsed as JSON, checked, re-encoded and written
 * to a fixed path, then install-policy runs with fixed arguments. The flash
 * drive is written only when the content changed (invariant 1).
 */
declare(strict_types=1);

require_once __DIR__ . '/status.php';

const CCU_POLICY_MAX_BYTES = 65536;
const CCU_POLICY_RULE_MAX = 300;
const CCU_POLICY_LISTS = ['allow', 'ask', 'deny'];
/** Keys the baseline sets; it loads last, so a drop-in value is ignored. */
const CCU_POLICY_LOCKED = [
    'permissions.defaultMode',
    'permissions.disableBypassPermissionsMode',
    'permissions.disableAutoMode',
    'disableAutoMode',
    'disableRemoteControl',
    'cleanupPeriodDays',
    'env.DISABLE_UPDATES',
    'env.DISABLE_AUTOUPDATER',
];

function ccu_policy_display_path(): string
{
    return '/boot/config/plugins/' . CCU_PLUGIN . '/policy.d/webgui.json';
}

function ccu_policy_path(): string
{
    return (string) getenv('ROOT') . ccu_policy_display_path();
}

function ccu_policy_read(): string
{
    $file = ccu_policy_path();
    if (!is_file($file) || (int) @filesize($file) > CCU_POLICY_MAX_BYTES) {
        return '';
    }
    $raw = @file_get_contents($file);
    return $raw === false ? '' : $raw;
}

/** True when $dotted (a.b.c) names a key present in the decoded object tree. */
function ccu_policy_has_key(object $obj, string $dotted): bool
{
    $node = $obj;
    foreach (explode('.', $dotted) as $part) {
        if (!is_object($node) || !property_exists($node, $part)) {
            return false;
        }
        $node = $node->{$part};
    }
    return true;
}

function ccu_validate_policy(string $raw): array
{
    $raw = trim($raw);
    if ($raw === '') {
        return ['ok' => true, 'errors' => [], 'notes' => [], 'json' => null];
    }
    if (strlen($raw) > CCU_POLICY_MAX_BYTES) {
        return ['ok' => false, 'errors' => ['the policy is larger than 64 KiB'], 'notes' => [], 'json' => null];
    }
    try {
        // Objects stay objects (stdClass) so that {} survives re-encoding;
        // an assoc decode would turn {"permissions": {}} into a list.
        $obj = json_decode($raw, false, 32, JSON_THROW_ON_ERROR);
    } catch (JsonException $e) {
        return ['ok' => false, 'errors' => ['not valid JSON: ' . $e->getMessage()], 'notes' => [], 'json' => null];
    }
    if (!is_object($obj)) {
        return ['ok' => false, 'errors' => ['the policy must be a JSON object, for example { "permissions": { "allow": [ ... ] } }'], 'notes' => [], 'json' => null];
    }
    if (get_object_vars($obj) === []) {
        return ['ok' => true, 'errors' => [], 'notes' => [], 'json' => null];
    }

    $errors = [];
    if (property_exists($obj, 'permissions')) {
        $perm = $obj->permissions;
        if (!is_object($perm)) {
            $errors[] = '"permissions" must be an object holding "allow", "ask" or "deny" lists';
        } else {
            foreach (CCU_POLICY_LISTS as $list) {
                if (!property_exists($perm, $list)) {
                    continue;
                }
                $rules = $perm->{$list};
                if (!is_array($rules)) {
                    $errors[] = "\"permissions.$list\" must be a list of rule strings";
                    continue;
                }
                foreach ($rules as $i => $rule) {
                    if (!is_string($rule) || trim($rule) === '' || strlen($rule) > CCU_POLICY_RULE_MAX || preg_match('/[\x00-\x1f\x7f]/', $rule)) {
                        $errors[] = "\"permissions.$list\" entry " . ((int) $i + 1) . ' is not a rule string, for example "Bash(docker compose *)"';
                    }
                }
            }
        }
    }
    $notes = [];
    foreach (CCU_POLICY_LOCKED as $dotted) {
        if (ccu_policy_has_key($obj, $dotted)) {
            $notes[] = "$dotted is set by the plugin's baseline, which loads last; the value here has no effect";
        }
    }
    if ($errors !== []) {
        return ['ok' => false, 'errors' => $errors, 'notes' => $notes, 'json' => null];
    }
    $json = json_encode($obj, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR) . "\n";
    return ['ok' => true, 'errors' => [], 'notes' => $notes, 'json' => $json];
}

/** Run install-policy (fixed path, no arguments); returns [rc, output lines]. */
function ccu_run_install_policy(): array
{
    $bin = (string) getenv('ROOT') . '/usr/local/emhttp/plugins/' . CCU_PLUGIN . '/scripts/install-policy';
    $out = [];
    $rc = 1;
    exec('timeout 30 ' . escapeshellarg($bin) . ' 2>&1', $out, $rc);
    $clean = [];
    foreach ($out as $line) {
        $line = preg_replace('/[\x00-\x08\x0b-\x1f\x7f]/', '', (string) $line) ?? '';
        if (trim($line) !== '') {
            $clean[] = $line;
        }
    }
    return [$rc, $clean];
}

function ccu_policy_save(string $raw): array
{
    $v = ccu_validate_policy($raw);
    if (!$v['ok']) {
        return ['ok' => false, 'action' => 'policy-save', 'error' => implode("\n", $v['errors']), 'errors' => $v['errors'], 'notes' => $v['notes']];
    }
    $file = ccu_policy_path();
    $shown = ccu_policy_display_path();
    $output = [];
    $changed = false;
    if ($v['json'] === null) {
        if (is_file($file)) {
            if (!@unlink($file)) {
                return ['ok' => false, 'action' => 'policy-save', 'error' => "could not remove $shown"];
            }
            $changed = true;
            $output[] = "policy drop-in removed: $shown";
        } else {
            $output[] = 'no policy drop-in to remove';
        }
    } else {
        $current = is_file($file) ? @file_get_contents($file) : false;
        if ($current === $v['json']) {
            $output[] = 'policy unchanged';
        } else {
            $dir = dirname($file);
            if (!is_dir($dir) && !@mkdir($dir, 0755, true)) {
                return ['ok' => false, 'action' => 'policy-save', 'error' => "could not create $shown (is the flash drive writable?)"];
            }
            $tmp = $dir . '/.webgui.' . bin2hex(random_bytes(4)) . '.tmp';
            if (@file_put_contents($tmp, $v['json']) !== strlen($v['json']) || !@rename($tmp, $file)) {
                @unlink($tmp);
                return ['ok' => false, 'action' => 'policy-save', 'error' => "could not write $shown (is the flash drive writable?)"];
            }
            $changed = true;
            $output[] = "policy saved to $shown";
        }
    }
    foreach ($v['notes'] as $note) {
        $output[] = "note: $note";
    }
    if ($changed) {
        [, $lines] = ccu_run_install_policy();
        foreach ($lines as $line) {
            $output[] = $line;
        }
        $output[] = 'policy applied: sessions started from now on use it; running sessions keep the old one until restarted';
    }
    return ['ok' => true, 'action' => 'policy-save', 'changed' => $changed, 'output' => $output];
}
