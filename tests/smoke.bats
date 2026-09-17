#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "repository has the expected top-level directories" {
    for d in lib bin tests vm vm/profiles boot media vendor docs; do
        [ -d "$REPO/$d" ] || { echo "missing directory: $d"; return 1; }
    done
}

@test "the Tier 2 quarantine ignores its own contents" {
    [ -f "$REPO/vendor/reference/.gitignore" ]
}
