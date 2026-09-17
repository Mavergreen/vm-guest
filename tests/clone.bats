#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export GOLDEN_DIR="$BATS_TEST_TMPDIR/golden"
    export WORK_DIR="$BATS_TEST_TMPDIR/work"
    mkdir -p "$GOLDEN_DIR"
    qemu-img create -f qcow2 "$BATS_TEST_TMPDIR/src.qcow2" 1M >/dev/null
    "$REPO/vm/golden.sh" promote "$BATS_TEST_TMPDIR/src.qcow2" base "test" >/dev/null 2>&1
}

@test "clone.sh creates an overlay backed by the golden" {
    run "$REPO/vm/clone.sh" base exp1
    [ "$status" -eq 0 ]
    [ -f "$WORK_DIR/exp1.qcow2" ]
    run qemu-img info "$WORK_DIR/exp1.qcow2"
    [[ "$output" == *"$GOLDEN_DIR/base.qcow2"* ]]
}

@test "clone.sh leaves the golden read-only and unmodified" {
    before=$(sha256sum "$GOLDEN_DIR/base.qcow2" | cut -d' ' -f1)
    "$REPO/vm/clone.sh" base exp1
    after=$(sha256sum "$GOLDEN_DIR/base.qcow2" | cut -d' ' -f1)
    [ "$before" = "$after" ]
    [ ! -w "$GOLDEN_DIR/base.qcow2" ]
}

@test "clone.sh defaults the clone name from the golden name" {
    run "$REPO/vm/clone.sh" base
    [ "$status" -eq 0 ]
    ls "$WORK_DIR" | grep -q '^base-'
}

@test "clone.sh refuses to overwrite an existing clone" {
    "$REPO/vm/clone.sh" base exp1
    run "$REPO/vm/clone.sh" base exp1
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}

@test "clone.sh fails for an unknown golden" {
    run "$REPO/vm/clone.sh" nosuch exp1
    [ "$status" -ne 0 ]
}

# --- Additional coverage found during verification ---

@test "clone.sh --verify passes for an untouched golden and still creates the clone" {
    run "$REPO/vm/clone.sh" --verify base exp1
    [ "$status" -eq 0 ]
    [ -f "$WORK_DIR/exp1.qcow2" ]
}

@test "clone.sh --verify fails loudly for a corrupted golden and creates no clone" {
    chmod u+w "$GOLDEN_DIR/base.qcow2"
    printf 'corruption' >> "$GOLDEN_DIR/base.qcow2"
    chmod u-w "$GOLDEN_DIR/base.qcow2"
    run "$REPO/vm/clone.sh" --verify base exp1
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
    [ ! -e "$WORK_DIR/exp1.qcow2" ]
}

@test "clone.sh without --verify does not read the whole golden" {
    # Plain clone.sh must not shell out to golden_verify at all -- confirmed
    # indirectly: a corrupted golden (bad checksum) still clones fine
    # without --verify, since the backing-file relationship doesn't require
    # re-hashing the golden.
    chmod u+w "$GOLDEN_DIR/base.qcow2"
    printf 'corruption' >> "$GOLDEN_DIR/base.qcow2"
    chmod u-w "$GOLDEN_DIR/base.qcow2"
    run "$REPO/vm/clone.sh" base exp1
    [ "$status" -eq 0 ]
    [ -f "$WORK_DIR/exp1.qcow2" ]
}

@test "clone.sh records an absolute backing file path" {
    "$REPO/vm/clone.sh" base exp1
    run qemu-img info "$WORK_DIR/exp1.qcow2"
    [[ "$output" == *"backing file: /"* ]]
}

@test "QEMU can open a clone whose golden is read-only (dry run via qemu-img check)" {
    "$REPO/vm/clone.sh" base exp1
    run qemu-img check "$WORK_DIR/exp1.qcow2"
    [ "$status" -eq 0 ]
}
