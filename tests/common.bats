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

@test "sha256_file fails loudly on a file it cannot read" {
    if [ "$(id -u)" -eq 0 ]; then
        skip "root bypasses permission checks, so this file would still be readable"
    fi
    printf 'hello\n' > "$BATS_TEST_TMPDIR/unreadable"
    chmod 000 "$BATS_TEST_TMPDIR/unreadable"
    run sha256_file "$BATS_TEST_TMPDIR/unreadable"
    chmod 600 "$BATS_TEST_TMPDIR/unreadable"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read"* ]]
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
    real_run_log_lines=$(cat "$REPO/run.log" 2>/dev/null | wc -l)
    # Stub repo_root so this writes into the bats tmpdir instead of the
    # repository's real (gitignored, append-only) run.log.
    repo_root() { echo "$BATS_TEST_TMPDIR"; }
    run_log "did a thing"
    [ -f "$BATS_TEST_TMPDIR/run.log" ]
    run cat "$BATS_TEST_TMPDIR/run.log"
    [[ "$output" == *"did a thing"* ]]
    # Assert this test did not touch the repo's real run log -- NOT that no
    # run log exists. A repo where the VM has actually been run has one, and
    # asserting its absence made this test pass only on machines that had
    # never used the tool.
    [ "$(cat "$REPO/run.log" 2>/dev/null | wc -l)" = "$real_run_log_lines" ]
    # The run log is the project's evidence trail: a UTC timestamp (ending
    # in Z, not local time), a literal TAB, then the message verbatim. A
    # silent drift in either would quietly corrupt its parseability.
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
    [[ "$output" == *"$(printf '\t')did a thing" ]]
}

@test "repo_root resolves to the actual repository root" {
    want=$(git -C "$REPO" rev-parse --show-toplevel)
    got=$(repo_root)
    [ "$got" = "$want" ]
}

@test "log writes to stderr, not stdout, with the mqg: prefix" {
    out=$(log "hello there" 2>/dev/null)
    err=$(log "hello there" 2>&1 1>/dev/null)
    [ -z "$out" ]
    [ "$err" = "mqg: hello there" ]
}

@test "warn writes to stderr, not stdout, with the mqg: warning: prefix" {
    out=$(warn "heads up" 2>/dev/null)
    err=$(warn "heads up" 2>&1 1>/dev/null)
    [ -z "$out" ]
    [ "$err" = "mqg: warning: heads up" ]
}

@test "MQG_LOG_PREFIX override is honored" {
    run bash -c '
        MQG_LOG_PREFIX="custom"
        # shellcheck source=/dev/null
        source "'"$REPO"'/lib/common.sh"
        log "hi"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "custom: hi" ]
}

@test "vmavs_hint is silent when nobody is watching -- this is why the suite stays green" {
    run bash -c "source '$REPO/lib/common.sh'; vmavs_hint image"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "vmavs_hint names the vmavs equivalent when forced" {
    run bash -c "source '$REPO/lib/common.sh'; VMAVS_FORCE_HINT=1 vmavs_hint image"
    [[ "$output" == *"vmavs image"* ]]
}

@test "vmavs_hint stays silent under bin/vmavs, even when forced" {
    # bin/vmavs sets VMAVS_DISPATCHED before it execs a script; the human
    # already typed the vmavs form and must not be told to type it.
    run bash -c "source '$REPO/lib/common.sh'; VMAVS_DISPATCHED=1 VMAVS_FORCE_HINT=1 vmavs_hint image"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "every script vmavs dispatches to calls vmavs_hint" {
    for s in image/build-image.sh bin/triangulate.sh vm/run.sh vm/clone.sh \
             vm/golden.sh image/compare-images.sh; do
        run grep -c 'vmavs_hint' "$REPO/$s"
        [ "$output" -ge 1 ] || { echo "no hint in $s"; false; }
    done
}

@test "the docs invoke vmavs, not the scripts" {
    # NOTES.md is excluded on purpose: it is the append-only lab log and
    # rewriting what was run would falsify it. docs/triangulation/*.md is
    # excluded for the same reason -- those are dated run records (what
    # command was actually run, on what day) and rewriting them would
    # falsify the record. docs/superpowers/plans/ is excluded because the
    # plan says so.
    run bash -c "grep -rn '\./image/build-image\.sh\|\./bin/triangulate\.sh\|\./vm/run\.sh' \
        '$REPO/README.md' '$REPO/docs' --include='*.md' \
        | grep -v 'docs/superpowers/plans/' \
        | grep -v 'docs/triangulation/' | wc -l"
    [ "$output" = "0" ]
}
