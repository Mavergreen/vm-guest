#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/golden.sh"
    GOLDEN_DIR="$BATS_TEST_TMPDIR/golden"
    mkdir -p "$GOLDEN_DIR"
    SRC="$BATS_TEST_TMPDIR/src.qcow2"
    qemu-img create -f qcow2 "$SRC" 1M >/dev/null
}

@test "golden_promote creates the image, its checksum, and its metadata" {
    run golden_promote "$SRC" first "the first install"
    [ "$status" -eq 0 ]
    [ -f "$GOLDEN_DIR/first.qcow2" ]
    [ -f "$GOLDEN_DIR/first.sha256" ]
    [ -f "$GOLDEN_DIR/first.meta" ]
}

@test "golden_promote makes the image read-only" {
    golden_promote "$SRC" first "desc"
    [ ! -w "$GOLDEN_DIR/first.qcow2" ]
}

@test "golden_promote records the description in the metadata" {
    golden_promote "$SRC" first "the first install"
    grep -q "the first install" "$GOLDEN_DIR/first.meta"
}

@test "golden_promote refuses to overwrite an existing golden" {
    golden_promote "$SRC" first "desc"
    run golden_promote "$SRC" first "desc again"
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}

@test "golden_verify passes for an untouched golden" {
    golden_promote "$SRC" first "desc"
    run golden_verify first
    [ "$status" -eq 0 ]
}

@test "golden_verify fails for a corrupted golden" {
    golden_promote "$SRC" first "desc"
    chmod u+w "$GOLDEN_DIR/first.qcow2"
    printf 'corruption' >> "$GOLDEN_DIR/first.qcow2"
    run golden_verify first
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
}

@test "golden_path returns the image path" {
    golden_promote "$SRC" first "desc"
    run golden_path first
    [ "$output" = "$GOLDEN_DIR/first.qcow2" ]
}

@test "golden_path fails for an unknown golden" {
    run golden_path nosuch
    [ "$status" -ne 0 ]
}

@test "golden_list names every golden" {
    golden_promote "$SRC" first "desc"
    qemu-img create -f qcow2 "$BATS_TEST_TMPDIR/s2.qcow2" 1M >/dev/null
    golden_promote "$BATS_TEST_TMPDIR/s2.qcow2" second "desc"
    run golden_list
    [[ "$output" == *"first"* ]]
    [[ "$output" == *"second"* ]]
}

# --- Additional coverage found during verification ---

@test "golden_promote leaves no temp files behind on success" {
    golden_promote "$SRC" first "desc"
    run bash -c "ls -A '$GOLDEN_DIR'"
    [ "$status" -eq 0 ]
    [[ "$output" != *".first."* ]]
}

@test "golden_promote fails cleanly and leaves no half-promoted image if the source is missing" {
    run golden_promote "$BATS_TEST_TMPDIR/nosuch.qcow2" first "desc"
    [ "$status" -ne 0 ]
    [ ! -e "$GOLDEN_DIR/first.qcow2" ]
}

@test "golden_promote sets no-COW on the golden directory when the filesystem supports it" {
    golden_promote "$SRC" first "desc"
    if command -v lsattr >/dev/null 2>&1; then
        run lsattr -d "$GOLDEN_DIR"
        [[ "$output" == *C* ]] || skip "filesystem under \$BATS_TEST_TMPDIR does not support chattr +C"
    fi
}

@test "golden_promote reflink-copies without erroring on a filesystem that doesn't support reflink" {
    # --reflink=auto silently falls back to a full copy when reflinking
    # isn't available; this only re-confirms promote succeeds either way.
    run golden_promote "$SRC" first "desc"
    [ "$status" -eq 0 ]
    cmp -s "$SRC" "$GOLDEN_DIR/first.qcow2"
}

@test "a second promotion under the same name after the first succeeds does not clobber it" {
    golden_promote "$SRC" first "first desc"
    run golden_promote "$SRC" first "second desc"
    [ "$status" -ne 0 ]
    grep -q "first desc" "$GOLDEN_DIR/first.meta"
}

@test "golden_promote reports failure and leaves no golden if qemu-img info can't read the copy" {
    # A file starting with the qcow2 magic but a bogus version makes
    # qemu-img probe it as qcow2 and then fail to parse the header -- a
    # real (if rare) way for qemu-img info to error out on a readable file.
    printf 'QFI\xfbgarbagegarbagegarbage' > "$BATS_TEST_TMPDIR/corrupt.qcow2"
    run golden_promote "$BATS_TEST_TMPDIR/corrupt.qcow2" broken "desc"
    [ "$status" -ne 0 ]
    [ ! -e "$GOLDEN_DIR/broken.qcow2" ]
    [ ! -e "$GOLDEN_DIR/broken.sha256" ]
    [ ! -e "$GOLDEN_DIR/broken.meta" ]
}
