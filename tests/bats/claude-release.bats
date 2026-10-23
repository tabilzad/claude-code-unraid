#!/usr/bin/env bats
# scripts/claude-release against a fixture bucket signed with throwaway keys.
# Everything runs offline: the bucket is a directory served over file://.

load '../helpers/fixtures'

SCRIPT="$REPO_ROOT/scripts/claude-release"

setup_file() {
  # The key-file override is only accepted for files under tests/, so the
  # exported throwaway public keys live there for the duration of this file.
  # The GNUPGHOME and the bucket stay in the container's own /tmp: gpg-agent
  # needs a unix socket, which a bind-mounted checkout may not allow.
  KEYDIR="$REPO_ROOT/tests/.tmp/claude-release-$$"
  TEST_GNUPGHOME="$BATS_FILE_TMPDIR/gnupg"
  BUCKET="$BATS_FILE_TMPDIR/bucket"
  export KEYDIR TEST_GNUPGHOME BUCKET
  mkdir -p "$BUCKET" "$KEYDIR"
  mkdir -m 0700 "$TEST_GNUPGHOME"

  gen_key 'Good Signer <good@example.test>'
  gen_key 'Wrong Signer <wrong@example.test>'
  local fprs
  mapfile -t fprs < <(gpg --homedir "$TEST_GNUPGHOME" --batch --with-colons --list-keys 2>/dev/null |
    awk -F: '$1=="pub"{p=1;next} $1=="fpr" && p==1 {print $10; p=0}')
  GOOD_FPR=${fprs[0]}
  WRONG_FPR=${fprs[1]}
  export GOOD_FPR WRONG_FPR
  gpg --homedir "$TEST_GNUPGHOME" --batch --armor --export "$GOOD_FPR" >"$KEYDIR/good.asc"
  gpg --homedir "$TEST_GNUPGHOME" --batch --armor --export "$WRONG_FPR" >"$KEYDIR/wrong.asc"
  gpg --homedir "$TEST_GNUPGHOME" --batch --armor --export "$GOOD_FPR" "$WRONG_FPR" >"$KEYDIR/two.asc"

  # 1.2.3: a good release. 1.2.4: tampered after signing. 1.2.5: platform
  # missing. 1.2.6: malformed checksum. 1.2.7: signed by the wrong key.
  # 1.2.8: manifest claims another version. 1.2.9: bad binary.
  make_release 1.2.3 good
  make_release 1.2.4 good
  printf ' ' >>"$BUCKET/1.2.4/manifest.json"
  make_release 1.2.5 good linux-arm64
  make_release 1.2.6 good linux-x64 'not-a-checksum'
  make_release 1.2.7 wrong
  make_release 1.2.8 good linux-x64 '' 9.9.9
  make_release 1.2.9 good
  printf 'tampered' >>"$BUCKET/1.2.9/linux-x64/claude"
  printf '1.2.3\n' >"$BUCKET/stable"
  printf 'nonsense\n' >"$BUCKET/latest"
}

teardown_file() {
  gpgconf --homedir "$TEST_GNUPGHOME" --kill gpg-agent 2>/dev/null || true
  rm -rf "$KEYDIR"
}

gen_key() {
  gpg --homedir "$TEST_GNUPGHOME" --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "$1" ed25519 sign never 2>/dev/null
}

# make_release VERSION good|wrong [PLATFORM] [CHECKSUM] [MANIFEST_VERSION]
make_release() {
  local ver=$1 signer=$2 platform=${3:-linux-x64} checksum=${4:-} mver=${5:-$1}
  local dir="$BUCKET/$ver"
  mkdir -p "$dir/linux-x64"
  printf 'fake claude %s\n' "$ver" >"$dir/linux-x64/claude"
  [ -n "$checksum" ] || checksum=$(sha256sum "$dir/linux-x64/claude" | cut -d' ' -f1)
  local size
  size=$(stat -c %s "$dir/linux-x64/claude")
  cat >"$dir/manifest.json" <<JSON
{
  "version": "$mver",
  "commit": "abc",
  "platforms": {
    "$platform": { "binary": "claude", "checksum": "$checksum", "size": $size },
    "darwin-arm64": { "binary": "claude", "checksum": "$(printf '%064d' 0)", "size": 1 }
  }
}
JSON
  local fpr=$GOOD_FPR
  [ "$signer" = wrong ] && fpr=$WRONG_FPR
  gpg --homedir "$TEST_GNUPGHOME" --batch --yes --quiet --pinentry-mode loopback --passphrase '' \
    --local-user "$fpr" --detach-sign --output "$dir/manifest.json.sig" "$dir/manifest.json" 2>/dev/null
}

# release ARGS...  runs the script in test mode against the fixture bucket
release() {
  CLAUDE_RELEASE_TEST_MODE=1 \
    CLAUDE_RELEASE_BASE_URL="file://$BUCKET" \
    CLAUDE_RELEASE_KEY_FILE="${KEY_FILE_OVERRIDE:-$KEYDIR/good.asc}" \
    CLAUDE_RELEASE_FINGERPRINT="${FPR_OVERRIDE:-$GOOD_FPR}" \
    "$SCRIPT" "$@"
}

good_checksum() {
  sha256sum "$BUCKET/1.2.3/linux-x64/claude" | cut -d' ' -f1
}

@test "verify: good signature prints the lock fields" {
  run release verify --version 1.2.3
  [ "$status" -eq 0 ]
  assert_contains "$output" "CLAUDE_VERSION=1.2.3"
  assert_contains "$output" "CLAUDE_PLATFORM=linux-x64"
  assert_contains "$output" "CLAUDE_SHA256=$(good_checksum)"
  assert_contains "$output" "CLAUDE_URL=file://$BUCKET/1.2.3/linux-x64/claude"
  assert_contains "$output" "CLAUDE_SIZE=$(stat -c %s "$BUCKET/1.2.3/linux-x64/claude")"
  assert_contains "$output" "MANIFEST_SHA256=$(sha256sum "$BUCKET/1.2.3/manifest.json" | cut -d' ' -f1)"
  assert_contains "$output" "VERIFIED_AT="
}

@test "verify: a manifest modified after signing is rejected" {
  run release verify --version 1.2.4
  [ "$status" -ne 0 ]
  assert_contains "$output" "signature rejected: BADSIG"
  assert_not_contains "$output" "CLAUDE_SHA256="
}

@test "verify: a key file with the wrong fingerprint is rejected" {
  KEY_FILE_OVERRIDE="$KEYDIR/wrong.asc" run release verify --version 1.2.3
  [ "$status" -ne 0 ]
  assert_contains "$output" "does not match the pinned fingerprint"
}

@test "verify: a key file with two keys is rejected" {
  KEY_FILE_OVERRIDE="$KEYDIR/two.asc" run release verify --version 1.2.3
  [ "$status" -ne 0 ]
  assert_contains "$output" "exactly one primary key"
}

@test "verify: a manifest signed by another key is rejected" {
  run release verify --version 1.2.7
  [ "$status" -ne 0 ]
  assert_contains "$output" "signature rejected: ERRSIG"
}

@test "verify: a manifest without the platform is rejected" {
  run release verify --version 1.2.5
  [ "$status" -ne 0 ]
  assert_contains "$output" 'platform "linux-x64" is missing'
}

@test "verify: a malformed checksum is rejected" {
  run release verify --version 1.2.6
  [ "$status" -ne 0 ]
  assert_contains "$output" "checksum for \"linux-x64\" is malformed"
}

@test "verify: a manifest for another version is rejected" {
  run release verify --version 1.2.8
  [ "$status" -ne 0 ]
  assert_contains "$output" "version field is '9.9.9', expected 1.2.8"
}

@test "verify: non-semver versions are rejected before any download" {
  for v in 1.2 v1.2.3 '1.2.3;id' '1.2.3/../x' ''; do
    run release verify --version "$v"
    [ "$status" -ne 0 ]
    assert_not_contains "$output" "fetching"
  done
}

@test "verify --download: checks the binary hash and size" {
  run release verify --version 1.2.3 --download
  [ "$status" -eq 0 ]
  assert_contains "$output" "binary OK"
  run release verify --version 1.2.9 --download
  [ "$status" -ne 0 ]
  assert_contains "$output" "binary sha256 mismatch"
}

@test "resolve: reads the channel file and validates it" {
  run --separate-stderr release resolve --channel stable
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.3" ]
  run release resolve --channel latest
  [ "$status" -ne 0 ]
  assert_contains "$output" "not a release version"
  run release resolve --channel beta
  [ "$status" -ne 0 ]
}

@test "lock: writes the lock file atomically with a header" {
  local out="$BATS_TEST_TMPDIR/claude-code.lock"
  run release lock --version 1.2.3 --out "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q '^# Claude Code release pinned' "$out"
  grep -q "^CLAUDE_SHA256=$(good_checksum)\$" "$out"
  grep -q '^CLAUDE_VERSION=1.2.3$' "$out"
  [ -z "$(find "$(dirname "$out")" -name '.lock.*')" ]
  run --separate-stderr release current --lock "$out"
  [ "$output" = "1.2.3" ]
}

@test "bump-candidate: prints the newer channel version, nothing otherwise" {
  local lock="$BATS_TEST_TMPDIR/lock"
  printf 'CLAUDE_VERSION=1.0.0\n' >"$lock"
  run --separate-stderr release bump-candidate --channel stable --lock "$lock"
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.3" ]
  printf 'CLAUDE_VERSION=1.2.3\n' >"$lock"
  run --separate-stderr release bump-candidate --channel stable --lock "$lock"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'CLAUDE_VERSION=1.10.0\n' >"$lock"
  run --separate-stderr release bump-candidate --channel stable --lock "$lock"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "test-mode overrides are refused outside test mode" {
  CLAUDE_RELEASE_KEY_FILE="$KEYDIR/good.asc" run "$SCRIPT" verify --version 1.2.3
  [ "$status" -ne 0 ]
  assert_contains "$output" "only honoured with CLAUDE_RELEASE_TEST_MODE=1"
  CLAUDE_RELEASE_BASE_URL="file://$BUCKET" run "$SCRIPT" verify --version 1.2.3
  [ "$status" -ne 0 ]
  assert_contains "$output" "only honoured with CLAUDE_RELEASE_TEST_MODE=1"
  CLAUDE_RELEASE_FINGERPRINT="$GOOD_FPR" run "$SCRIPT" verify --version 1.2.3
  [ "$status" -ne 0 ]
  assert_contains "$output" "only honoured with CLAUDE_RELEASE_TEST_MODE=1"
}

@test "test-mode key override must live under tests/" {
  cp "$KEYDIR/good.asc" "$BATS_TEST_TMPDIR/outside.asc"
  KEY_FILE_OVERRIDE="$BATS_TEST_TMPDIR/outside.asc" run release verify --version 1.2.3
  [ "$status" -ne 0 ]
  assert_contains "$output" "must be under"
}

@test "test-mode base URL must be local" {
  CLAUDE_RELEASE_TEST_MODE=1 CLAUDE_RELEASE_BASE_URL="https://example.com/bucket" run "$SCRIPT" resolve --channel stable
  [ "$status" -ne 0 ]
  assert_contains "$output" "must start with file:///"
}

@test "the shipped key has the pinned fingerprint" {
  local home="$BATS_TEST_TMPDIR/g"
  mkdir -m 0700 "$home"
  gpg --homedir "$home" --batch --quiet --import "$REPO_ROOT/keys/claude-code.asc" 2>/dev/null
  run gpg --homedir "$home" --batch --with-colons --list-keys
  assert_contains "$output" "fpr:::::::::31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE:"
  gpgconf --homedir "$home" --kill gpg-agent 2>/dev/null || true
}
