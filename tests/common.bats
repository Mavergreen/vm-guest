#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
}

@test "sha256_file computes a known checksum" {
    printf 'hello\n' > "$BATS_TEST_TMPDIR/f"
    run sha256_file "$BATS_TEST_TMPDIR/f"
    [ "$status" -eq 0 ]
    [ "$output" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]
}

@test "sha256_file fails loudly on a missing file" {
    run sha256_file "$BATS_TEST_TMPDIR/nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such file"* ]]
}

@test "verify_sha256 accepts a matching checksum" {
    printf 'hello\n' > "$BATS_TEST_TMPDIR/f"
    run verify_sha256 "$BATS_TEST_TMPDIR/f" \
        "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
    [ "$status" -eq 0 ]
}

@test "verify_sha256 rejects a mismatching checksum and names both values" {
    printf 'hello\n' > "$BATS_TEST_TMPDIR/f"
    run verify_sha256 "$BATS_TEST_TMPDIR/f" "0000000000000000000000000000000000000000000000000000000000000000"
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
    [[ "$output" == *"5891b5b5"* ]]
}

@test "require_cmd succeeds for commands that exist" {
    run require_cmd sh cat
    [ "$status" -eq 0 ]
}

@test "require_cmd fails and names the missing command" {
    run require_cmd sh definitely-not-a-real-command-xyz
    [ "$status" -ne 0 ]
    [[ "$output" == *"definitely-not-a-real-command-xyz"* ]]
}

@test "die exits non-zero with its message on stderr" {
    run die "the thing broke"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the thing broke"* ]]
}

@test "run_log appends a timestamped line, isolated from the real run.log" {
    # Stub repo_root so this writes into the bats tmpdir instead of the
    # repository's real (gitignored, append-only) run.log.
    repo_root() { echo "$BATS_TEST_TMPDIR"; }
    run_log "did a thing"
    [ -f "$BATS_TEST_TMPDIR/run.log" ]
    run cat "$BATS_TEST_TMPDIR/run.log"
    [[ "$output" == *"did a thing"* ]]
    [ ! -e "$REPO/run.log" ]
}
