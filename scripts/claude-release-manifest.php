#!/usr/bin/env php
<?php
/*
 * Extract the fields scripts/claude-release needs from a Claude Code release
 * manifest, after its signature has been verified.
 *
 *   claude-release-manifest.php MANIFEST PLATFORM EXPECTED_VERSION
 *
 * Prints CHECKSUM=..., SIZE=... and MANIFEST_VERSION=... on success. Exits 1
 * with a reason on stderr when the manifest is not a JSON object, the platform
 * is missing, the checksum is not 64 lowercase hex characters, the size is not
 * a positive integer, or the version does not match. Strictness here is what
 * keeps a confusing-but-signed manifest from pinning the wrong bytes.
 */
declare(strict_types=1);

function fail(string $msg): never
{
    fwrite(STDERR, "manifest: $msg\n");
    exit(1);
}

if ($argc !== 4) {
    fail('usage: claude-release-manifest.php MANIFEST PLATFORM EXPECTED_VERSION');
}
[, $path, $platform, $expectedVersion] = $argv;

if (!preg_match('/^[a-z0-9-]{3,32}$/', $platform)) {
    fail('platform name is malformed');
}
if (!preg_match('/^[0-9]+\.[0-9]+\.[0-9]+$/', $expectedVersion)) {
    fail('expected version is malformed');
}

$raw = @file_get_contents($path);
if ($raw === false || $raw === '') {
    fail("cannot read $path");
}
if (strlen($raw) > 1024 * 1024) {
    fail('manifest is unreasonably large');
}

try {
    $manifest = json_decode($raw, true, 16, JSON_THROW_ON_ERROR);
} catch (JsonException $e) {
    fail('invalid JSON: ' . $e->getMessage());
}
if (!is_array($manifest) || array_is_list($manifest)) {
    fail('top level is not a JSON object');
}

$version = $manifest['version'] ?? null;
if (!is_string($version) || $version !== $expectedVersion) {
    fail(sprintf('version field is %s, expected %s', var_export($version, true), $expectedVersion));
}

$platforms = $manifest['platforms'] ?? null;
if (!is_array($platforms) || array_is_list($platforms)) {
    fail('"platforms" is not a JSON object');
}
$entry = $platforms[$platform] ?? null;
if (!is_array($entry) || array_is_list($entry)) {
    fail("platform \"$platform\" is missing");
}

$checksum = $entry['checksum'] ?? null;
if (!is_string($checksum) || !preg_match('/^[a-f0-9]{64}$/', $checksum)) {
    fail("checksum for \"$platform\" is malformed");
}

$size = $entry['size'] ?? null;
if ($size === null) {
    $sizeOut = '';
} elseif (is_int($size) && $size > 0) {
    $sizeOut = (string) $size;
} else {
    fail("size for \"$platform\" is not a positive integer");
}

printf("CHECKSUM=%s\nSIZE=%s\nMANIFEST_VERSION=%s\n", $checksum, $sizeOut, $version);
