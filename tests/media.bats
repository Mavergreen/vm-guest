#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "fetch-installesd.sh prints the checksum it expects, without fetching" {
    run "$REPO/media/fetch-installesd.sh" --show-expected
    [ "$status" -eq 0 ]
    # A sha256 is 64 hex characters.
    [[ "$output" =~ [0-9a-f]{64} ]]
}

@test "fetch-installesd.sh refuses to run without the tools it needs" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for t in bash dirname; do ln -sf "$(command -v $t)" "$BATS_TEST_TMPDIR/bin/$t"; done
    run env PATH="$BATS_TEST_TMPDIR/bin" "$REPO/media/fetch-installesd.sh" --show-expected
    # --show-expected must work without curl; the fetch path must not.
    [ "$status" -eq 0 ]
    run env PATH="$BATS_TEST_TMPDIR/bin" "$REPO/media/fetch-installesd.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"curl"* ]]
}

@test "fetch-installesd.sh's pinned checksum matches the one in sources.tsv" {
    # Two places name this checksum: the script, so --show-expected needs
    # nothing but bash, and the registry, so it is recorded where every
    # other third-party artifact is. They must not drift apart.
    expected=$("$REPO/media/fetch-installesd.sh" --show-expected)
    recorded=$(awk -F'\t' '$1 == "apple-installesd-10.9.5" { print $3 }' \
        "$REPO/vendor/sources.tsv")
    [ -n "$recorded" ]
    [ "$expected" = "$recorded" ]
}

@test "fetch-installesd.sh leaves an already-verified download alone" {
    # The one byte of content whose sha256 we can state without a 5 GB
    # download: stand in for InstallESD.dmg by pinning the checksum to it.
    dir="$BATS_TEST_TMPDIR/images"
    mkdir -p "$dir/media"
    printf 'pretend installer\n' > "$dir/media/InstallESD.dmg"
    sum=$(sha256sum "$dir/media/InstallESD.dmg" | cut -d' ' -f1)
    run env MQG_IMAGE_DIR="$dir" MQG_INSTALLESD_SHA256="$sum" \
        "$REPO/media/fetch-installesd.sh"
    [ "$status" -eq 0 ]
    # The path is the last line: progress notes go to stderr, which bats
    # merges into $output.
    [ "${lines[${#lines[@]}-1]}" = "$dir/media/InstallESD.dmg" ]
    # Untouched, not re-fetched.
    run cat "$dir/media/InstallESD.dmg"
    [ "$output" = "pretend installer" ]
}

@test "fetch-installesd.sh rejects an already-present file that fails verification" {
    dir="$BATS_TEST_TMPDIR/images"
    mkdir -p "$dir/media"
    printf 'corrupted\n' > "$dir/media/InstallESD.dmg"
    run env MQG_IMAGE_DIR="$dir" \
        MQG_INSTALLESD_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
        "$REPO/media/fetch-installesd.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
    # It says what is wrong rather than silently deleting 5 GB.
    [ -f "$dir/media/InstallESD.dmg" ]
}

@test "fetch-installesd.sh never renames an unverified download into place" {
    # The point of the whole script: a partial or substituted download must
    # not become InstallESD.dmg. Serve it something wrong and check.
    dir="$BATS_TEST_TMPDIR/images"
    mkdir -p "$dir/media" "$BATS_TEST_TMPDIR/fake"
    printf 'not the installer\n' > "$BATS_TEST_TMPDIR/fake/payload"
    run env MQG_IMAGE_DIR="$dir" \
        MQG_INSTALLESD_URL="file://$BATS_TEST_TMPDIR/fake/payload" \
        "$REPO/media/fetch-installesd.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
    [ ! -f "$dir/media/InstallESD.dmg" ]
}
